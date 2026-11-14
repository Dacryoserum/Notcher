import Foundation
import CryptoKit

/// Self-update from GitHub releases, in three steps:
/// 1. *Check*: list the published releases, keep the newest one that ships a `latest.json` manifest and is
///    newer than this build.
/// 2. *Verify*: the archive must match the SHA-256 and the ed25519 signature of the manifest, checked
///    against the public key built into the app. The private key never leaves the release machine, so a
///    tampered download is refused.
/// 3. *Install*: done by the app (`UpdateService`), by swapping complete bundles.
/// This file holds what can be decided without a network or a file system.

/// `1.2.0` or `1.2.0-beta.2`. A version with a suffix comes before the same version without one.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let suffix: [String]
    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first else { return nil }
        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var parsed: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 9, field.allSatisfy(\.isASCII), field.allSatisfy(\.isNumber), let number = Int(field) else { return nil }
            parsed.append(number)
        }
        numbers = parsed
        suffix = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        if parts.count > 1 && suffix.isEmpty { return nil }
    }
    public var description: String { numbers.map(String.init).joined(separator: ".") + (suffix.isEmpty ? "" : "-" + suffix.joined(separator: ".")) }
    public static func == (left: AppVersion, right: AppVersion) -> Bool { !(left < right) && !(right < left) }
    public static func < (left: AppVersion, right: AppVersion) -> Bool {
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let a = index < left.numbers.count ? left.numbers[index] : 0, b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a < b }
        }
        if left.suffix.isEmpty || right.suffix.isEmpty { return !left.suffix.isEmpty && right.suffix.isEmpty }
        for index in 0..<min(left.suffix.count, right.suffix.count) {
            let a = left.suffix[index], b = right.suffix[index]
            if a == b { continue }
            // Numeric fields compare as numbers and come before words, as in semantic versioning.
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
        return left.suffix.count < right.suffix.count
    }
}

/// `latest.json`, attached to every release by `Scripts/release.sh`.
public struct UpdateManifest: Codable, Equatable, Sendable {
    /// Version without the leading `v`.
    public var version: String
    /// Release notes shown before installing.
    public var notes: String
    /// One archive per platform key (`macos-arm64`, `macos-x86_64`, `macos-universal`).
    public var assets: [String: UpdateAsset]
    public init(version: String, notes: String, assets: [String: UpdateAsset]) { self.version = version; self.notes = notes; self.assets = assets }
}

public struct UpdateAsset: Codable, Equatable, Sendable {
    public var url: String
    /// Lowercase hexadecimal SHA-256 of the archive.
    public var sha256: String
    /// Base64 ed25519 signature of the archive bytes.
    public var signature: String
    public var size: Int
    public init(url: String, sha256: String, signature: String, size: Int) { self.url = url; self.sha256 = sha256; self.signature = signature; self.size = size }
}

/// A newer version this Mac can install.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let asset: UpdateAsset
}

/// The part of GitHub's release list the updater reads.
public struct GithubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browser_download_url: String
        public init(name: String, browser_download_url: String) { self.name = name; self.browser_download_url = browser_download_url }
    }
    public let tag_name: String
    public let draft: Bool
    public let assets: [Asset]
    public init(tag_name: String, draft: Bool, assets: [Asset]) { self.tag_name = tag_name; self.draft = draft; self.assets = assets }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case hashMismatch, badSignature, badKey, tooLarge, insecureAddress
    public var errorDescription: String? {
        switch self {
        case .hashMismatch: return L("L’empreinte SHA-256 de la mise à jour ne correspond pas.")
        case .badSignature: return L("La signature de la mise à jour est invalide.")
        case .badKey: return L("La clé de vérification des mises à jour est invalide.")
        case .tooLarge: return L("La mise à jour est anormalement volumineuse.")
        case .insecureAddress: return L("L’adresse de la mise à jour n’est pas sûre.")
        }
    }
}

public enum Updates {
    public static let repository = "Dacryoserum/Notcher"
    /// Published releases, newest first.
    public static let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    public static let manifestName = "latest.json"
    /// Public half of the release signing key (ed25519, 32 bytes, base64). The private half stays in the
    /// keychain of the Mac that publishes releases. Written by `Scripts/release.sh --init-key`; while it is
    /// empty the app does not look for updates.
    public static let publicKey = "X9GO7aJ32dTK3/YfBmGytUSerqgw0DTKNKYxQSK77p0="
    public static var configured: Bool { !publicKey.isEmpty }
    /// No archive of this app comes anywhere near this size; a larger one is refused before it is read.
    public static let maximumArchiveSize = 200_000_000

    /// Archive keys this Mac can run, preferred first.
    public static var platformKeys: [String] {
        #if arch(arm64)
        return ["macos-arm64", "macos-universal"]
        #else
        return ["macos-x86_64", "macos-universal"]
        #endif
    }

    /// Address of the `latest.json` of the newest published release newer than `current`.
    public static func newestManifestURL(in releases: [GithubRelease], current: String) -> URL? {
        guard let running = AppVersion(current) else { return nil }
        let newer = releases.compactMap { release -> (AppVersion, URL)? in
            guard !release.draft, let version = AppVersion(release.tag_name), version > running,
                  let manifest = release.assets.first(where: { $0.name == manifestName }),
                  let url = secureURL(manifest.browser_download_url) else { return nil }
            return (version, url)
        }
        return newer.max { $0.0 < $1.0 }?.1
    }

    /// The update a manifest offers, when it is newer and ships an archive for one of `platforms`.
    public static func update(from manifest: UpdateManifest, current: String, platforms: [String] = platformKeys) -> AvailableUpdate? {
        guard let offered = AppVersion(manifest.version), let running = AppVersion(current), offered > running,
              let asset = platforms.lazy.compactMap({ manifest.assets[$0] }).first, secureURL(asset.url) != nil else { return nil }
        return AvailableUpdate(version: offered.description, notes: manifest.notes, asset: asset)
    }

    /// Only HTTPS addresses are ever requested.
    public static func secureURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Checks the SHA-256 and the ed25519 signature of an archive. Throws when either is wrong.
    public static func verify(_ archive: Data, asset: UpdateAsset, publicKey: String = publicKey) throws {
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { throw UpdateError.hashMismatch }
        guard let keyBytes = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { throw UpdateError.badKey }
        guard let signature = Data(base64Encoded: asset.signature.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64,
              key.isValidSignature(signature, for: archive) else { throw UpdateError.badSignature }
    }

    /// Signs an archive for a manifest. Used by the release script and the tests.
    public static func sign(_ archive: Data, url: String, privateKey: Curve25519.Signing.PrivateKey) throws -> UpdateAsset {
        UpdateAsset(url: url, sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                    signature: try privateKey.signature(for: archive).base64EncodedString(), size: archive.count)
    }
}

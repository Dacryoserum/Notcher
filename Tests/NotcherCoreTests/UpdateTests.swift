import XCTest
import CryptoKit
@testable import NotcherCore

final class UpdateTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, manifest: Bool = true) -> GithubRelease {
        GithubRelease(tag_name: tag, draft: draft, assets: manifest ? [.init(name: "latest.json", browser_download_url: "https://example.test/\(tag)/latest.json")] : [])
    }
    func testVersionsCompareByNumberThenSuffix() {
        XCTAssertTrue(AppVersion("1.1.0")! < AppVersion("1.2.0")!)
        XCTAssertTrue(AppVersion("1.9.0")! < AppVersion("1.10.0")!)
        XCTAssertTrue(AppVersion("v1.2")! == AppVersion("1.2.0")!)
        XCTAssertTrue(AppVersion("1.2.0-beta.2")! < AppVersion("1.2.0-beta.10")!)
        XCTAssertTrue(AppVersion("1.2.0-beta.10")! < AppVersion("1.2.0")!)
        XCTAssertTrue(AppVersion("1.2.0")! < AppVersion("1.2.1-alpha")!)
        for invalid in ["", "abc", "1..2", "1.2.x", "1.2.0-", "-1.0", "1.2.3.4.5"] { XCTAssertNil(AppVersion(invalid), invalid) }
    }
    func testNewestPublishedReleaseWithManifestWins() {
        let releases = [release("v1.5.0", draft: true), release("v1.4.0", manifest: false), release("v1.2.0"), release("v1.10.0"), release("v1.3.0"), release("nightly")]
        XCTAssertEqual(Updates.newestManifestURL(in: releases, current: "1.1.0")?.absoluteString, "https://example.test/v1.10.0/latest.json")
        XCTAssertNil(Updates.newestManifestURL(in: releases, current: "1.10.0"))
        XCTAssertNil(Updates.newestManifestURL(in: releases, current: "not a version"))
        // A manifest served over plain http is ignored.
        let insecure = GithubRelease(tag_name: "v9.0.0", draft: false, assets: [.init(name: "latest.json", browser_download_url: "http://example.test/latest.json")])
        XCTAssertNil(Updates.newestManifestURL(in: [insecure], current: "1.0.0"))
    }
    func testManifestOffersOnlyNewerVersionsForThisPlatform() throws {
        let json = #"{"version":"1.2.0","notes":"Notes","assets":{"macos-arm64":{"url":"https://example.test/a.zip","sha256":"s","signature":"g","size":3}}}"#
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        XCTAssertEqual(Updates.update(from: manifest, current: "1.1.0", platforms: ["macos-arm64"])?.version, "1.2.0")
        XCTAssertEqual(Updates.update(from: manifest, current: "1.1.0", platforms: ["macos-x86_64", "macos-arm64"])?.asset.size, 3)
        XCTAssertNil(Updates.update(from: manifest, current: "1.2.0", platforms: ["macos-arm64"]))
        XCTAssertNil(Updates.update(from: manifest, current: "1.3.0", platforms: ["macos-arm64"]))
        XCTAssertNil(Updates.update(from: manifest, current: "1.1.0", platforms: ["macos-x86_64"]))
        var insecure = manifest; insecure.assets["macos-arm64"]?.url = "http://example.test/a.zip"
        XCTAssertNil(Updates.update(from: insecure, current: "1.1.0", platforms: ["macos-arm64"]))
    }
    func testOnlyAnArchiveSignedWithTheBuiltInKeyIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey(), publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("archive bytes".utf8)
        let asset = try Updates.sign(archive, url: "https://example.test/a.zip", privateKey: key)
        XCTAssertNoThrow(try Updates.verify(archive, asset: asset, publicKey: publicKey))
        XCTAssertThrowsError(try Updates.verify(Data("tampered".utf8), asset: asset, publicKey: publicKey)) { XCTAssertEqual($0 as? UpdateError, .hashMismatch) }
        // Right hash, signature from another key: what someone replacing both the archive and the manifest could produce.
        let forged = try Updates.sign(archive, url: asset.url, privateKey: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try Updates.verify(archive, asset: forged, publicKey: publicKey)) { XCTAssertEqual($0 as? UpdateError, .badSignature) }
        var unsigned = asset; unsigned.signature = ""
        XCTAssertThrowsError(try Updates.verify(archive, asset: unsigned, publicKey: publicKey)) { XCTAssertEqual($0 as? UpdateError, .badSignature) }
        XCTAssertThrowsError(try Updates.verify(archive, asset: asset, publicKey: "")) { XCTAssertEqual($0 as? UpdateError, .badKey) }
    }
    func testTheBuiltInPublicKeyIsUsableOnceSet() throws {
        guard Updates.configured else { return } // Empty until `Scripts/release.sh --init-key` has run.
        let bytes = try XCTUnwrap(Data(base64Encoded: Updates.publicKey))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: bytes))
    }
}

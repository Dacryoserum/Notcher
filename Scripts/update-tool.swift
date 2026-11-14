import Foundation
import CryptoKit

// Signing side of the in-app updater (the app side is Sources/NotcherCore/Updates.swift).
//   swift Scripts/update-tool.swift keygen
//       prints a new ed25519 key pair: "private <base64>" then "public <base64>"
//   NOTCHER_UPDATE_SIGNING_KEY=<base64> swift Scripts/update-tool.swift public
//       prints the public key of the private key
//   NOTCHER_UPDATE_SIGNING_KEY=<base64> swift Scripts/update-tool.swift manifest <archive> <version> <platform> <url> <notes file or -> <output>
//       signs the archive and writes latest.json
// Scripts/release.sh calls it; the private key comes from the keychain and never touches the disk.

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

func signingKey() -> Curve25519.Signing.PrivateKey {
    let text = (ProcessInfo.processInfo.environment["NOTCHER_UPDATE_SIGNING_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        fail("NOTCHER_UPDATE_SIGNING_KEY is missing or is not a base64 ed25519 private key.")
    }
    return key
}

struct Asset: Encodable { let url: String; let sha256: String; let signature: String; let size: Int }
struct Manifest: Encodable { let version: String; let notes: String; let assets: [String: Asset] }

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private " + key.rawRepresentation.base64EncodedString())
    print("public " + key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(signingKey().publicKey.rawRepresentation.base64EncodedString())
case "manifest":
    guard arguments.count == 7 else { fail("Usage: manifest <archive> <version> <platform> <url> <notes file or -> <output>") }
    let key = signingKey()
    guard let archive = FileManager.default.contents(atPath: arguments[1]) else { fail("Cannot read \(arguments[1]).") }
    guard arguments[4].hasPrefix("https://") else { fail("The archive address must use https.") }
    let notes = arguments[5] == "-" ? "" : ((try? String(contentsOfFile: arguments[5], encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = try? key.signature(for: archive) else { fail("Signing failed.") }
    let asset = Asset(url: arguments[4], sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                      signature: signature.base64EncodedString(), size: archive.count)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(Manifest(version: arguments[2], notes: notes, assets: [arguments[3]: asset])) else { fail("Cannot encode the manifest.") }
    do { try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: arguments[6]), options: .atomic) } catch { fail("Cannot write \(arguments[6]).") }
    print("latest.json: \(arguments[2]) \(arguments[3]), \(archive.count) bytes, public key " + key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("Usage: update-tool.swift keygen | public | manifest <archive> <version> <platform> <url> <notes file or -> <output>")
}

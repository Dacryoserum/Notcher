import XCTest
import CryptoKit
@testable import Notcher
@testable import NotcherCore

final class UpdateIntegrationTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-update-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A minimal bundle: enough for the installer's checks, which read the Info.plist and the executable bit.
    private func makeBundle(in parent: URL, version: String, identifier: String = "fr.notcher.app") throws -> URL {
        let bundle = parent.appendingPathComponent("Notcher.app", isDirectory: true)
        let binaries = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Notcher"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let executable = binaries.appendingPathComponent("Notcher")
        try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return bundle
    }
    private func version(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
    private func archive(version: String, identifier: String = "fr.notcher.app") async throws -> Data {
        let staging = folder.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = try makeBundle(in: staging, version: version, identifier: identifier)
        let zip = staging.appendingPathComponent("Notcher.zip")
        let result = try await Command.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.path, zip.path])
        XCTAssertEqual(result.status, 0)
        return try Data(contentsOf: zip)
    }
    /// GitHub as the updater sees it: the release list, the manifest of the newest release, its archive.
    private func client(version: String, archive: Data, key: Curve25519.Signing.PrivateKey, served: Data? = nil) throws -> UpdateClient {
        let archiveURL = "https://example.test/v\(version)/Notcher.zip", manifestURL = "https://example.test/v\(version)/latest.json"
        let asset = try Updates.sign(archive, url: archiveURL, privateKey: key)
        let manifest = try JSONEncoder().encode(UpdateManifest(version: version, notes: "Nouveautés", assets: Dictionary(uniqueKeysWithValues: Updates.platformKeys.prefix(1).map { ($0, asset) })))
        let releases = Data(#"[{"tag_name":"v\#(version)","draft":false,"assets":[{"name":"latest.json","browser_download_url":"\#(manifestURL)"}]},{"tag_name":"v0.9.0","draft":false,"assets":[]}]"#.utf8)
        let body = served ?? archive
        return UpdateClient { url in
            switch url.absoluteString {
            case Updates.releasesURL.absoluteString: return releases
            case manifestURL: return manifest
            case archiveURL: return body
            default: throw CommandError.unavailable
            }
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "timed out")
    }

    @MainActor func testAvailableUpdateIsFoundInstalledAndRelaunched() async throws {
        let home = folder.appendingPathComponent("Applications", isDirectory: true)
        let bundle = try makeBundle(in: home, version: "1.1.0")
        let key = Curve25519.Signing.PrivateKey()
        var relaunched: URL?
        let service = UpdateService(client: try client(version: "1.2.0", archive: try await archive(version: "1.2.0"), key: key),
                                    currentVersion: "1.1.0", bundle: bundle, relaunch: { relaunched = $0 })
        XCTAssertNil(service.available)
        let found = try await UpdateService.find(client: try client(version: "1.2.0", archive: Data(), key: key), current: "1.2.0")
        XCTAssertNil(found, "the running version is not offered to itself")
        service.install() // Nothing to install yet: must do nothing.
        XCTAssertFalse(service.installing)
        let update = try await UpdateService.find(client: try client(version: "1.2.0", archive: try await archive(version: "1.2.0"), key: key), current: "1.1.0")
        XCTAssertEqual(update?.version, "1.2.0"); XCTAssertEqual(update?.notes, "Nouveautés")
        service.adopt(update)
        service.install(publicKey: key.publicKey.rawRepresentation.base64EncodedString(), checkCodeSignature: false)
        XCTAssertTrue(service.installing)
        try await wait { relaunched != nil || service.failed }
        XCTAssertFalse(service.failed, service.installStatus ?? "")
        XCTAssertEqual(relaunched, bundle)
        XCTAssertEqual(version(of: bundle), "1.2.0")
        let previous = URL(fileURLWithPath: bundle.path + ".old")
        XCTAssertEqual(version(of: previous), "1.1.0", "the replaced copy is kept until the next launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path + ".update"))
        UpdateInstaller.cleanUp(bundle: bundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(version(of: bundle), "1.2.0")
    }
    @MainActor func testTamperedDownloadLeavesTheInstalledCopyUntouched() async throws {
        let bundle = try makeBundle(in: folder.appendingPathComponent("Applications", isDirectory: true), version: "1.1.0")
        let key = Curve25519.Signing.PrivateKey()
        let genuine = try await archive(version: "1.2.0"), other = try await archive(version: "1.2.0", identifier: "fr.notcher.other")
        var relaunched = false
        // The manifest describes the genuine archive; the server hands out another one.
        let swapped = try client(version: "1.2.0", archive: genuine, key: key, served: other)
        let service = UpdateService(client: swapped, currentVersion: "1.1.0", bundle: bundle, relaunch: { _ in relaunched = true })
        service.adopt(try await UpdateService.find(client: swapped, current: "1.1.0"))
        service.install(publicKey: key.publicKey.rawRepresentation.base64EncodedString(), checkCodeSignature: false)
        try await wait { service.failed }
        XCTAssertFalse(relaunched); XCTAssertFalse(service.installing)
        XCTAssertEqual(version(of: bundle), "1.1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path + ".old"))
        // Correctly signed, but with a key the app does not trust.
        let stranger = try client(version: "1.2.0", archive: genuine, key: Curve25519.Signing.PrivateKey())
        let second = UpdateService(client: stranger, currentVersion: "1.1.0", bundle: bundle, relaunch: { _ in relaunched = true })
        second.adopt(try await UpdateService.find(client: stranger, current: "1.1.0"))
        second.install(publicKey: key.publicKey.rawRepresentation.base64EncodedString(), checkCodeSignature: false)
        try await wait { second.failed }
        XCTAssertFalse(relaunched)
        XCTAssertEqual(version(of: bundle), "1.1.0")
    }
    func testInstallerRefusesAnArchiveOfAnotherAppOrVersion() async throws {
        let bundle = try makeBundle(in: folder.appendingPathComponent("Applications", isDirectory: true), version: "1.1.0")
        for (shipped, identifier) in [("1.3.0", "fr.notcher.app"), ("1.2.0", "fr.notcher.other")] {
            let data = try await archive(version: shipped, identifier: identifier)
            do { try await UpdateInstaller.install(archive: data, version: "1.2.0", over: bundle, checkCodeSignature: false); XCTFail("accepted \(shipped) \(identifier)") } catch {}
            XCTAssertEqual(version(of: bundle), "1.1.0")
        }
        XCTAssertNotNil(UpdateInstaller.blocker(bundle: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Notcher.app")))
        XCTAssertNotNil(UpdateInstaller.blocker(bundle: folder.appendingPathComponent("debug")))
        XCTAssertNil(UpdateInstaller.blocker(bundle: bundle))
    }
    /// Each command used to leave its pipe open until Foundation released it, hundreds at a time.
    func testCommandsDoNotAccumulateOpenFiles() async throws {
        func openFiles() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        _ = try await Command.run("/usr/bin/true")
        let before = openFiles()
        for _ in 0..<60 { _ = try await Command.run("/bin/echo", ["notcher"]) }
        XCTAssertLessThanOrEqual(openFiles(), before + 4)
    }
}

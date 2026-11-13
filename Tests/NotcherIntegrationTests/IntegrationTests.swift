import XCTest
@testable import Notcher

final class IntegrationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // AppPaths is process-wide; all test artifacts stay in the explicitly isolated test root.
        setenv("NOTCHER_DATA_DIR", FileManager.default.temporaryDirectory.appendingPathComponent("notcher-integration-support-\(getpid())").path, 1)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testClaudeInstallPreservesSettingsAndRestoresPreviousStatusLine() throws {
        let settings = directory.appendingPathComponent("settings.json"), record = directory.appendingPathComponent("record.json")
        let original: [String: Any] = ["permissions": ["allow": ["Read"]], "statusLine": ["type": "command", "command": "printf 'existing status'", "padding": 2], "custom": true]
        let data = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try data.write(to: settings)
        try ClaudeIntegration.install(settingsURL: settings, recordURL: record, executablePath: "/tmp/test path/Notcher")
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(installed["custom"] as? Bool, true)
        XCTAssertEqual((installed["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
        let wrapper = try String(contentsOf: AppPaths.integrations.appendingPathComponent("claude-statusline.sh"), encoding: .utf8)
        XCTAssertTrue(wrapper.contains("--quiet"))
        XCTAssertTrue(wrapper.contains("existing status"))
        XCTAssertTrue(wrapper.contains("'/tmp/test path/Notcher'"))
        try ClaudeIntegration.uninstall(settingsURL: settings, recordURL: record)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: restored, options: [.sortedKeys]), data)
    }
    func testClaudeUninstallDoesNotOverwriteNewUserChanges() throws {
        let settings = directory.appendingPathComponent("settings.json"), record = directory.appendingPathComponent("record.json")
        try Data("{}".utf8).write(to: settings)
        try ClaudeIntegration.install(settingsURL: settings, recordURL: record, executablePath: "/tmp/Notcher")
        let edited = Data(#"{"statusLine":{"command":"my new command"}}"#.utf8)
        try edited.write(to: settings)
        XCTAssertThrowsError(try ClaudeIntegration.uninstall(settingsURL: settings, recordURL: record))
        XCTAssertEqual(try Data(contentsOf: settings), edited)
    }
    func testClaudeRefusesMalformedSettingsWithoutReplacingThem() throws {
        let settings = directory.appendingPathComponent("settings.json"), record = directory.appendingPathComponent("record.json")
        try Data("not json".utf8).write(to: settings)
        XCTAssertThrowsError(try ClaudeIntegration.install(settingsURL: settings, recordURL: record, executablePath: "/tmp/Notcher"))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }
    func testBoundedCommandDrainsLargeOutputWithoutDeadlocking() async throws {
        let result = try await Command.run("/usr/bin/awk", ["BEGIN { for (i=0; i<20000; i++) print \"abcdefghijklmnop\" }"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.data.count, 340_000)
    }
    func testCommandTimeoutTerminatesChild() async {
        do { _ = try await Command.run("/bin/sleep", ["30"], timeout: 0.1); XCTFail("Expected a timeout") }
        catch { XCTAssertTrue(error is CommandError) }
    }
    @MainActor func testCodexHandshakeAndFragmentedResponse() async throws {
        let fake = directory.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/perl
        use strict;
        use JSON::PP;
        $| = 1;
        my $initialized = 0;
        while (my $line = <STDIN>) {
            my $request = decode_json($line);
            if ($request->{method} eq 'initialize') {
                print encode_json({id=>$request->{id}, result=>{userAgent=>'test'}})."\n";
            } elsif ($request->{method} eq 'initialized') {
                $initialized = 1;
            } elsif ($request->{method} eq 'account/rateLimits/read') {
                if (!$initialized) { exit 7; }
                my $out = encode_json({id=>$request->{id}, result=>{rateLimits=>{primary=>{usedPercent=>42,windowDurationMins=>300}}}})."\n";
                print substr($out,0,15);
                select(undef,undef,undef,0.03);
                print substr($out,15);
            }
        }
        """#
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        try AppPaths.prepare()
        let client = CodexClient()
        defer { client.disconnect() }
        try await client.connect(path: fake.path)
        let result = try await client.readLimits()
        let json = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let window = ((json["rateLimits"] as? [String: Any])?["primary"] as? [String: Any])
        XCTAssertEqual(window?["usedPercent"] as? Int, 42)
    }
}

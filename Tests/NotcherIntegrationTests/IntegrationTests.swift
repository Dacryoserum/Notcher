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
    func testClaudeHooksSitNextToTheUsersOwnAndLeaveWithoutThem() throws {
        let settings = directory.appendingPathComponent("settings.json"), record = directory.appendingPathComponent("record.json")
        let own: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/mine"]]]
        let original: [String: Any] = ["hooks": ["PreToolUse": [own], "Stop": [own]]]
        let data = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try data.write(to: settings)
        try ClaudeIntegration.install(settingsURL: settings, recordURL: record, executablePath: "/tmp/test path/Notcher")
        // Refreshing an up-to-date installation adds nothing twice.
        try ClaudeIntegration.refreshHooks(settingsURL: settings, executablePath: "/tmp/test path/Notcher")
        let hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["PreToolUse"]?.count, 1)
        XCTAssertEqual(hooks["Stop"]?.count, 2)
        for event in ClaudeIntegration.hookEvents {
            let commands = hooks[event]?.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } } ?? []
            XCTAssertEqual(commands.filter { $0 == ClaudeIntegration.hookCommand }.count, 1, event)
        }
        let wrapper = try String(contentsOf: ClaudeIntegration.hookWrapper, encoding: .utf8)
        XCTAssertTrue(wrapper.contains("exec '/tmp/test path/Notcher' --claude-event"))
        try ClaudeIntegration.uninstall(settingsURL: settings, recordURL: record)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: restored, options: [.sortedKeys]), data)
    }
    func testCodexHookSitsNextToTheUsersOwnAndLeavesWithoutThem() throws {
        let hooks = directory.appendingPathComponent("hooks.json")
        // No file yet: Notcher creates it, and removes it again when its entry was the only thing in it.
        try CodexIntegration.install(hooksURL: hooks, executablePath: "/tmp/test path/Notcher")
        try CodexIntegration.install(hooksURL: hooks, executablePath: "/tmp/test path/Notcher")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: [String: [[String: Any]]]])
        XCTAssertEqual(root["hooks"]?["PermissionRequest"]?.count, 1)
        XCTAssertTrue(try String(contentsOf: CodexIntegration.wrapper, encoding: .utf8).contains("exec '/tmp/test path/Notcher' --codex-permission"))
        try CodexIntegration.uninstall(hooksURL: hooks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path))
        // The user's own hooks come back byte for byte.
        let own: [String: Any] = ["description": "mine", "hooks": ["PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/policy"]]]], "Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let data = try JSONSerialization.data(withJSONObject: own, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooks)
        try CodexIntegration.install(hooksURL: hooks, executablePath: "/tmp/Notcher")
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any])["hooks"].flatMap { ["hooks": $0 as! [String: [[String: Any]]]] } ?? [:]
        XCTAssertEqual(root["hooks"]?["PermissionRequest"]?.count, 2)
        try CodexIntegration.uninstall(hooksURL: hooks)
        XCTAssertEqual(try Data(contentsOf: hooks), data)
        // A file Notcher cannot read is never rewritten.
        try Data("not json".utf8).write(to: hooks)
        try CodexIntegration.install(hooksURL: hooks, executablePath: "/tmp/Notcher")
        XCTAssertEqual(try String(contentsOf: hooks, encoding: .utf8), "not json")
    }
    /// Quotas once stopped arriving because the relay still named an app that was no longer there.
    func testStatusLineRelayFollowsTheAppAndKeepsTheUsersOwnStatusLine() throws {
        let settings = directory.appendingPathComponent("settings.json"), record = directory.appendingPathComponent("record.json")
        try Data(#"{"statusLine":{"type":"command","command":"printf mine"}}"#.utf8).write(to: settings)
        try ClaudeIntegration.install(settingsURL: settings, recordURL: record, executablePath: "/old place/Notcher")
        try ClaudeIntegration.refreshHooks(settingsURL: settings, recordURL: record, executablePath: "/new place/Notcher")
        let script = try String(contentsOf: ClaudeIntegration.statusWrapper, encoding: .utf8)
        XCTAssertFalse(script.contains("/old place"))
        XCTAssertTrue(script.contains("if [ -x '/new place/Notcher' ]; then printf '%s' \"$input\" | '/new place/Notcher' --claude-statusline --quiet; fi"))
        XCTAssertTrue(script.contains("| /bin/sh -c 'printf mine'"), "The status line the user had still runs, even if the app is gone")
        // Without a status line of the user's, Notcher prints its own.
        XCTAssertFalse(ClaudeIntegration.statusScript(executable: "/a/Notcher", previousCommand: nil).contains("--quiet"))
        try ClaudeIntegration.uninstall(settingsURL: settings, recordURL: record)
    }
    func testOlderInstallationGainsTheHooksOnRefresh() throws {
        let settings = directory.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"x"},"hooks":{"Stop":"not a list"}}"#.utf8).write(to: settings)
        try ClaudeIntegration.refreshHooks(settingsURL: settings, executablePath: "/tmp/Notcher")
        let hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["hooks"] as! [String: Any]
        XCTAssertEqual(hooks["Stop"] as? String, "not a list") // What Notcher does not understand is left alone.
        XCTAssertEqual((hooks["UserPromptSubmit"] as? [Any])?.count, 1)
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

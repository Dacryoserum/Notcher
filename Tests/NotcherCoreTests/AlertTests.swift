import XCTest
@testable import NotcherCore

final class AlertTests: XCTestCase {
    func testBatteryWarnsOncePerThresholdAndAnnouncesAFullCharge() {
        var watch = BatteryWatch()
        // Opened at 15 %: the 20 % warning is already past and is not given at launch.
        XCTAssertNil(watch.update(level: 15, charging: false))
        XCTAssertNil(watch.update(level: 14, charging: false))
        XCTAssertEqual(watch.update(level: 10, charging: false), .low(10))
        XCTAssertNil(watch.update(level: 9, charging: false))
        // Charging past a threshold makes it count again.
        XCTAssertNil(watch.update(level: 50, charging: true))
        XCTAssertNil(watch.update(level: 99, charging: true))
        XCTAssertEqual(watch.update(level: 100, charging: true), .full)
        XCTAssertNil(watch.update(level: 100, charging: true))
        XCTAssertNil(watch.update(level: 21, charging: false))
        XCTAssertEqual(watch.update(level: 20, charging: false), .low(20))
        // A fall across both thresholds at once is one warning.
        var other = BatteryWatch()
        _ = other.update(level: 22, charging: false)
        XCTAssertEqual(other.update(level: 8, charging: false), .low(8))
        XCTAssertNil(other.update(level: 7, charging: false))
        // Plugged in while already full: nothing new.
        var full = BatteryWatch()
        _ = full.update(level: 100, charging: false)
        XCTAssertNil(full.update(level: 100, charging: true))
    }
    func testScreenshotsAreRecognisedByNameAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 14, minute: 3, second: 20)))
        func capture(_ name: String, custom: String? = nil) -> Bool { ScreenshotWatch.isCapture("/Users/me/Desktop/" + name, customName: custom, now: now, calendar: calendar) }
        XCTAssertTrue(capture("Capture d’écran 2026-11-22 à 14.03.11.png"))
        XCTAssertTrue(capture("Screenshot 2026-11-22 at 2.03.11 PM.png"))
        XCTAssertTrue(capture("Screen Recording 2026-11-22 at 14.02.40.mov"))
        XCTAssertTrue(capture("Shot 2026-11-22 at 14.03.11.png", custom: "Shot"))
        XCTAssertTrue(capture("Screenshot.png"), "a name without a date cannot be dated")
        // An old capture moved to the Bin is renamed too, but its time gives it away.
        XCTAssertFalse(capture("Capture d’écran 2026-11-22 à 09.12.00.png"))
        XCTAssertFalse(capture("Capture d’écran 2026-11-20 à 14.03.11.png"))
        XCTAssertFalse(capture(".Capture d’écran 2026-11-22 à 14.03.11.png"))
        XCTAssertFalse(capture("Capture d’écran 2026-11-22 à 14.03.11.txt"))
        XCTAssertFalse(capture("Holidays 2026-11-22 at 14.03.11.png"))
    }
    func testShellCommandsAreReducedToWhatTheyShip() {
        XCTAssertEqual(ShipAction.classify(#"git add -A && git commit -m "fix: x""#), .commit)
        XCTAssertEqual(ShipAction.classify("git commit -m wip && git push origin main"), .push)
        XCTAssertEqual(ShipAction.classify("git -C ~/code/app push"), .push)
        XCTAssertEqual(ShipAction.classify("GIT_EDITOR=true git commit --amend"), .commit)
        XCTAssertEqual(ShipAction.classify(#"gh pr create --title "x" --body "y""#), .pullRequest)
        XCTAssertEqual(ShipAction.classify("npx vercel --prod"), .deploy)
        XCTAssertEqual(ShipAction.classify("fly deploy"), .deploy)
        XCTAssertNil(ShipAction.classify("git status && git log --oneline | head"))
        XCTAssertNil(ShipAction.classify("git push --dry-run"))
        XCTAssertNil(ShipAction.classify("echo git commit"))
        XCTAssertNil(ShipAction.classify("gh pr list"))
    }
    func testHookEventsCarryTheShipActionNotTheCommand() {
        let input = Data(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"git push origin secret-branch"}}"#.utf8)
        XCTAssertEqual(ClaudeEvent.parse(input), ClaudeEvent(kind: .tool, session: "s", detail: "push"))
        let failed = Data(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}"#.utf8)
        XCTAssertEqual(ClaudeEvent.parse(failed), ClaudeEvent(kind: .toolFailure, session: "s", detail: "commit"))
        let edit = Data(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Edit","tool_input":{"command":"git push"}}"#.utf8)
        XCTAssertEqual(ClaudeEvent.parse(edit)?.detail, nil)
        // A failing tool still means the session is at work.
        var sessions = ClaudeSessions()
        sessions.apply(ClaudeEvent(kind: .toolFailure, session: "s"))
        XCTAssertEqual(sessions.working, 1)
    }
}

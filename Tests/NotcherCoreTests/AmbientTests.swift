import XCTest
@testable import NotcherCore

final class AmbientTests: XCTestCase {
    private func event(_ kind: ClaudeEvent.Kind, _ session: String = "a", detail: String? = nil) -> ClaudeEvent { ClaudeEvent(kind: kind, session: session, detail: detail) }

    func testHookInputIsReducedToEventSessionAndNoticeType() {
        let input = Data(#"{"hook_event_name":"Notification","session_id":"abc","notification_type":"permission_prompt","message":"secret text","cwd":"/private"}"#.utf8)
        XCTAssertEqual(ClaudeEvent.parse(input), ClaudeEvent(kind: .attention, session: "abc", detail: "permission_prompt"))
        XCTAssertNil(ClaudeEvent.parse(Data(#"{"hook_event_name":"PreCompact","session_id":"abc"}"#.utf8)))
        XCTAssertNil(ClaudeEvent.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8)))
        XCTAssertNil(ClaudeEvent.parse(Data("not json".utf8)))
    }
    func testAnswerIsCountedFromPromptToStop() {
        var sessions = ClaudeSessions()
        XCTAssertFalse(sessions.apply(event(.prompt)))
        XCTAssertFalse(sessions.apply(event(.prompt, "b")))
        XCTAssertEqual(sessions.working, 2)
        XCTAssertTrue(sessions.apply(event(.stop)))
        XCTAssertEqual(sessions.working, 1)
        XCTAssertFalse(sessions.apply(event(.end, "b")))
        XCTAssertEqual(sessions.working, 0)
    }
    func testPermissionRequestWaitsUntilTheNextToolRuns() {
        var sessions = ClaudeSessions()
        sessions.apply(event(.prompt))
        sessions.apply(event(.attention, detail: "permission_prompt"))
        XCTAssertEqual([sessions.working, sessions.waiting], [0, 1])
        sessions.apply(event(.tool))
        XCTAssertEqual([sessions.working, sessions.waiting], [1, 0])
    }
    func testIdleNoticeAfterAnAnswerIsNotARequest() {
        var sessions = ClaudeSessions()
        sessions.apply(event(.prompt)); sessions.apply(event(.stop))
        sessions.apply(event(.attention, detail: "idle_prompt"))
        sessions.apply(event(.attention))
        XCTAssertEqual([sessions.working, sessions.waiting], [0, 0])
        // An untyped notice during an answer is one.
        sessions.apply(event(.prompt)); sessions.apply(event(.attention))
        XCTAssertEqual(sessions.waiting, 1)
    }
    func testInterruptedAnswerStopsCountingAfterSilence() {
        var sessions = ClaudeSessions()
        let start = Date(timeIntervalSince1970: 1_000)
        sessions.apply(event(.prompt), at: start)
        sessions.apply(event(.attention, "b", detail: "permission_prompt"), at: start)
        sessions.prune(at: start.addingTimeInterval(ClaudeSessions.workingLimit - 1))
        XCTAssertEqual(sessions.working, 1)
        sessions.prune(at: start.addingTimeInterval(ClaudeSessions.workingLimit + 1))
        XCTAssertEqual([sessions.working, sessions.waiting], [0, 1])
        sessions.prune(at: start.addingTimeInterval(ClaudeSessions.waitingLimit + 1))
        XCTAssertEqual(sessions.waiting, 0)
    }
    func testDownloadIsFinishedWhenAPartialFileBecomesARegularOne() {
        let folder = "/Users/me/Downloads"
        XCTAssertEqual(DownloadWatch.finished(renamed: ["\(folder)/Unconfirmed 12.crdownload", "\(folder)/report.pdf"], folder: folder), "\(folder)/report.pdf")
        XCTAssertEqual(DownloadWatch.finished(renamed: ["\(folder)/movie.mp4.download/movie.mp4", "\(folder)/movie.mp4"], folder: folder + "/"), "\(folder)/movie.mp4")
        // Renaming or deleting an ordinary file is not a download.
        XCTAssertNil(DownloadWatch.finished(renamed: ["\(folder)/a.pdf", "\(folder)/b.pdf"], folder: folder))
        XCTAssertNil(DownloadWatch.finished(renamed: ["\(folder)/a.pdf", "/Users/me/.Trash/a.pdf"], folder: folder))
        // A download still in progress, or landing in a subfolder, is not announced.
        XCTAssertNil(DownloadWatch.finished(renamed: ["\(folder)/a.crdownload"], folder: folder))
        XCTAssertNil(DownloadWatch.finished(renamed: ["\(folder)/a.part", "\(folder)/sub/a.zip"], folder: folder))
    }
    func testPictureOnlyStatesUseTheNarrowWing() {
        let bare = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: false, idleInfo: false)
        let ambient = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: false, idleInfo: false, ambient: true)
        let titled = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: true, idleInfo: false)
        XCTAssertEqual(bare.width, 218)
        XCTAssertEqual(ambient.width, 334)
        XCTAssertGreaterThan(titled.width, ambient.width)
    }
}

import XCTest
@testable import NotcherCore

final class UsageHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Paris")!; return value
    }
    private func day(_ offset: Int, hour: Int = 12, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!)!
    }
    func testDaysCountsAndStreak() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 18)))
        let records = [
            UsageRecord(date: day(0, from: now), tokens: 100, session: "a", model: "opus", key: "m1:r1"),
            UsageRecord(date: day(0, from: now), tokens: 100, session: "a", model: "opus", key: "m1:r1"), // the same answer written twice
            UsageRecord(date: day(-1, from: now), tokens: 50, session: "b", model: "sonnet", key: "m2:r2"),
            UsageRecord(date: day(-2, from: now), tokens: 30, session: "b", model: "sonnet", key: "m3:r3"),
            UsageRecord(date: day(-4, from: now), tokens: 70, session: "c", model: "sonnet", key: "m4:r4"),
            UsageRecord(date: day(-40, from: now), tokens: 999, session: "old"),
        ]
        let history = UsageHistory(records: records, now: now, calendar: calendar)
        XCTAssertEqual(history.days.count, 30)
        XCTAssertEqual(history.today, 100)
        XCTAssertEqual(history.total, 250)
        XCTAssertEqual(history.sessions, 3)
        XCTAssertEqual(history.activeDays, 4)
        XCTAssertEqual(history.streak, 3)
        XCTAssertEqual(history.favoriteModel, "sonnet")
        // Nothing yet today does not break the streak of the days before.
        let morning = UsageHistory(records: Array(records.dropFirst(2)), now: now, calendar: calendar)
        XCTAssertEqual(morning.streak, 2)
    }
    func testLogLinesKeepOnlyCounts() throws {
        let claude = Data(#"{"type":"assistant","timestamp":"2026-11-22T20:09:49.788Z","sessionId":"s1","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","text":"secret"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":20,"cache_read_input_tokens":300,"output_tokens":40}}}"#.utf8)
        let record = try XCTUnwrap(UsageLog.claude(claude))
        XCTAssertEqual(record.tokens, 362); XCTAssertEqual(record.session, "s1"); XCTAssertEqual(record.key, "msg_1:req_1"); XCTAssertEqual(record.model, "claude-opus-5-5")
        XCTAssertNil(UsageLog.claude(Data(#"{"type":"user","timestamp":"2026-11-22T20:09:49.788Z","message":{"content":"hi"}}"#.utf8)))
        let codex = Data(#"{"timestamp":"2026-10-14T12:32:42.289Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":14750,"output_tokens":31,"total_tokens":14781}}}}"#.utf8)
        XCTAssertEqual(UsageLog.codex(codex, session: "x")?.tokens, 14781)
        XCTAssertEqual(UsageHistory.short(12_400_000, locale: Locale(identifier: "fr_FR")), "12 M")
        XCTAssertEqual(UsageHistory.short(1_250_000, locale: Locale(identifier: "en_US")), "1.2 M")
        XCTAssertEqual(UsageHistory.short(830, locale: Locale(identifier: "fr_FR")), "830")
    }
}

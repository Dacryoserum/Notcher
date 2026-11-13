import XCTest
@testable import NotcherCore

final class UsageTests: XCTestCase {
    func testClaudeAbsentQuotasAreNotZero() throws {
        let value = try UsageParser.claude(Data(#"{"model":{"display_name":"Claude"},"rate_limits":{"five_hour":null},"context_window":{"used_percentage":null}}"#.utf8))
        XCTAssertTrue(value.windows.isEmpty)
        XCTAssertNil(value.contextPercent)
    }
    func testClaudePreservesReportedUsageAndExpiresAtBoundary() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":2000},"seven_day":{"used_percentage":127,"resets_at":3000}}}"#
        let usage = try UsageParser.claude(Data(json.utf8))
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].usedPercent, 0)
        XCTAssertFalse(usage.windows[0].isExpired(at: Date(timeIntervalSince1970: 1999)))
        XCTAssertTrue(usage.windows[0].isExpired(at: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(usage.windows[1].usedPercent, 127)
        XCTAssertEqual(usage.windows[1].fraction, 1)
    }
    func testMalformedMetricsAreIgnored() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":true},"seven_day":{"used_percentage":-3},"spend_limit":{"used_percentage":"72"}}}"#
        XCTAssertTrue(try UsageParser.claude(Data(json.utf8)).windows.isEmpty)
    }
    func testCodexSelectsCorrectBucketAndWindowDurations() throws {
        let json = #"{"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":5000},"secondary":{"usedPercent":64,"windowDurationMins":10080}},"other":{"primary":{"usedPercent":88}}}}}"#
        let usage = try UsageParser.codex(Data(json.utf8))
        XCTAssertEqual(usage.windows.map(\.usedPercent), [24, 64])
        XCTAssertEqual(usage.windows.map(\.title), ["5 heures", "7 jours"])
        XCTAssertNil(usage.windows[1].resetsAt)
    }
    func testCodexNotificationsAndMissingWindows() throws {
        let json = #"{"params":{"rateLimits":{"primary":null,"secondary":{"usedPercent":0,"windowDurationMins":30}}}}"#
        let usage = try UsageParser.codex(Data(json.utf8))
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].title, "30 min")
        XCTAssertEqual(usage.windows[0].usedPercent, 0)
    }
    func testCodexDoesNotUseAnUnrelatedBucket() throws {
        let json = #"{"rateLimits":{"limitId":"other","primary":{"usedPercent":70}}}"#
        XCTAssertTrue(try UsageParser.codex(Data(json.utf8)).windows.isEmpty)
    }
    func testSanitizationDoesNotCollectPromptsPathsOrCredentials() throws {
        let json = #"{"session_id":"secret","cwd":"/private/project","transcript_path":"/private/log","prompt":"sensitive","api_key":"secret","model":{"display_name":"Claude","secret":"no"},"cost":{"total_cost_usd":1.2,"private":"no"},"rate_limits":{"five_hour":{"used_percentage":45,"resets_at":5000,"secret":"no"},"secret":{"value":"no"}}}"#
        let data = try UsageParser.sanitizedClaudeSnapshot(Data(json.utf8), at: Date(timeIntervalSince1970: 1234))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("sensitive"))
        let value = try UsageParser.claude(data)
        XCTAssertEqual(value.capturedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(value.sessionCost, 1.2)
        XCTAssertEqual(value.windows.first?.usedPercent, 45)
    }
    func testInvalidRootThrowsAndStaleDataIsIdentified() {
        XCTAssertThrowsError(try UsageParser.codex(Data("[]".utf8)))
        let usage = AgentUsage(provider: "Codex", capturedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(usage.isStale(at: Date(timeIntervalSince1970: 500)))
        XCTAssertTrue(usage.isStale(at: Date(timeIntervalSince1970: 601)))
    }
}

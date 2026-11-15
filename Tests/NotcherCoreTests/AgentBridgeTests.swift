import XCTest
@testable import NotcherCore

final class AgentBridgeTests: XCTestCase {
    func testSubagentsAreFollowedFromStartToStop() {
        var sessions = ClaudeSessions()
        let start = Date(timeIntervalSince1970: 1000)
        let input = Data(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"agent-1","agent_type":"Explore","cwd":"/private"}"#.utf8)
        let parsed = ClaudeEvent.parse(input)
        XCTAssertEqual(parsed, ClaudeEvent(kind: .subagentStart, session: "s", agent: "agent-1", agentType: "Explore"))
        sessions.apply(parsed!, at: start)
        sessions.apply(ClaudeEvent(kind: .subagentStart, session: "s", agent: "agent-2", agentType: "general-purpose"), at: start.addingTimeInterval(1))
        sessions.apply(ClaudeEvent(kind: .subagentStart, session: "other", agent: "agent-3"), at: start.addingTimeInterval(2))
        XCTAssertEqual(sessions.subagents.map(\.type), ["Explore", "general-purpose", "Agent"])
        sessions.apply(ClaudeEvent(kind: .subagentStop, session: "s", agent: "agent-1"))
        XCTAssertEqual(sessions.subagents.map(\.id), ["agent-2", "agent-3"])
        // A session that ends takes its helpers with it; the others stay.
        sessions.apply(ClaudeEvent(kind: .end, session: "s"))
        XCTAssertEqual(sessions.subagents.map(\.id), ["agent-3"])
        // One that never reports its end is forgotten.
        sessions.prune(at: start.addingTimeInterval(ClaudeSessions.subagentLimit + 10))
        XCTAssertTrue(sessions.subagents.isEmpty)
    }
    func testPermissionRequestKeepsOnlyWhatIsNeededToDecide() throws {
        let input = Data(#"{"hook_event_name":"PermissionRequest","session_id":"abc","cwd":"/Users/me/code/shop","transcript_path":"/secret","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules"},"permission_suggestions":[]}"#.utf8)
        let request = try XCTUnwrap(ClaudePermissionRequest.parse(input))
        XCTAssertEqual(request, ClaudePermissionRequest(session: "abc", tool: "Bash", summary: "rm -rf node_modules", note: "Remove node_modules", project: "shop"))
        let write = Data((#"{"hook_event_name":"PermissionRequest","session_id":"abc","tool_name":"Write","tool_input":{"file_path":"/tmp/a.txt","content":""# + String(repeating: "x", count: 5000) + #""}}"#).utf8)
        XCTAssertEqual(ClaudePermissionRequest.parse(write)?.summary, "/tmp/a.txt")
        let long = Data((#"{"hook_event_name":"PermissionRequest","session_id":"abc","tool_name":"Bash","tool_input":{"command":""# + String(repeating: "y", count: 5000) + #""}}"#).utf8)
        XCTAssertEqual(ClaudePermissionRequest.parse(long)?.summary.count, 600)
        // Codex asks in the same words; only the name on the card changes.
        XCTAssertEqual(ClaudePermissionRequest.parse(input, agent: .codex)?.agent, .codex)
        XCTAssertEqual(request.agent, .claude)
        XCTAssertNil(ClaudePermissionRequest.parse(Data(#"{"hook_event_name":"PreToolUse","session_id":"abc","tool_name":"Bash"}"#.utf8)))
        XCTAssertNil(ClaudePermissionRequest.parse(Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)))
        XCTAssertEqual(ClaudePermissionRequest(session: "s", tool: "mcp__github__create_issue", summary: "").toolTitle, "github · create_issue")
    }
    func testAnswerIsWrittenTheWayClaudeCodeReadsIt() throws {
        func decision(_ answer: ClaudePermissionAnswer) throws -> [String: Any]? {
            guard let data = answer.hookOutput(denyMessage: "no") else { return nil }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
            return specific["decision"] as? [String: Any]
        }
        XCTAssertEqual(try decision(.allow) as? [String: String], ["behavior": "allow"])
        XCTAssertEqual(try decision(.deny) as? [String: String], ["behavior": "deny", "message": "no"])
        // Saying nothing leaves Claude Code's own prompt in charge.
        XCTAssertNil(try decision(.pass))
    }
    func testCoverColourIsItsMostVividOneMadeReadableOnBlack() throws {
        func pixels(_ colours: [(UInt8, UInt8, UInt8, Int)]) -> [UInt8] { colours.flatMap { colour in (0..<colour.3).flatMap { _ in [colour.0, colour.1, colour.2, 255] } } }
        // A dark blue cover with a little grey: the answer is blue, and bright.
        let blue = try XCTUnwrap(CoverTint.dominant(rgba: pixels([(10, 20, 90, 300), (128, 128, 128, 200), (0, 0, 0, 76)])))
        XCTAssertGreaterThan(blue.blue, blue.red); XCTAssertGreaterThan(blue.blue, blue.green)
        XCTAssertGreaterThanOrEqual(blue.blue, 0.89)
        XCTAssertGreaterThanOrEqual(min(blue.red, blue.green), 0.2)
        // Nothing to name in black and white.
        XCTAssertNil(CoverTint.dominant(rgba: pixels([(0, 0, 0, 300), (255, 255, 255, 200), (90, 90, 90, 76)])))
        XCTAssertNil(CoverTint.dominant(rgba: []))
    }
}

import Foundation

/// What a Claude Code hook reports, reduced to the fields Notcher uses. Nothing of the conversation is kept.
public struct ClaudeEvent: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case prompt = "UserPromptSubmit", tool = "PostToolUse", attention = "Notification", stop = "Stop", end = "SessionEnd"
        case subagentStart = "SubagentStart", subagentStop = "SubagentStop", toolFailure = "PostToolUseFailure"
    }
    public var kind: Kind
    public var session: String
    /// Notification type ("permission_prompt", "idle_prompt"…) when Claude Code gives one; for a shell command,
    /// what it ships (`ShipAction`), never the command itself.
    public var detail: String?
    /// The sub-agent an event comes from, and its kind ("Explore", "general-purpose"…).
    public var agent: String?
    public var agentType: String?
    public init(kind: Kind, session: String, detail: String? = nil, agent: String? = nil, agentType: String? = nil) {
        self.kind = kind; self.session = session; self.detail = detail; self.agent = agent; self.agentType = agentType
    }
    /// Reads the JSON a hook receives on its standard input.
    public static func parse(_ data: Data) -> ClaudeEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["hook_event_name"] as? String, let kind = Kind(rawValue: name),
              let session = root["session_id"] as? String, !session.isEmpty, session.count <= 200 else { return nil }
        func short(_ key: String) -> String? { (root[key] as? String).flatMap { $0.isEmpty || $0.count > 120 ? nil : $0 } }
        var detail = root["notification_type"] as? String
        if kind == .tool || kind == .toolFailure, root["tool_name"] as? String == "Bash",
           let command = (root["tool_input"] as? [String: Any])?["command"] as? String, command.count <= 20_000 {
            detail = ShipAction.classify(command)?.rawValue
        }
        return ClaudeEvent(kind: kind, session: session, detail: detail, agent: short("agent_id"), agentType: short("agent_type"))
    }
}

/// A helper Claude Code started inside a session to work on part of the task.
public struct ClaudeSubagent: Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var session: String
    public var started: Date
}

/// Which Claude Code sessions are answering and which are waiting for the user, rebuilt from hook events.
public struct ClaudeSessions: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case working, waiting }
    private struct Entry: Equatable, Sendable { var phase: Phase; var seen: Date }
    private var entries: [String: Entry] = [:]
    private var helpers: [String: ClaudeSubagent] = [:]
    /// A sub-agent that ends without a word (interrupted session) is forgotten after this long.
    public static let subagentLimit: TimeInterval = 45 * 60
    /// Sub-agents at work, oldest first.
    public var subagents: [ClaudeSubagent] { helpers.values.sorted { ($0.started, $0.id) < ($1.started, $1.id) } }
    /// An interrupted answer sends no event: a session silent for this long is no longer counted as working.
    public static let workingLimit: TimeInterval = 15 * 60
    public static let waitingLimit: TimeInterval = 2 * 3600
    public init() {}
    public var working: Int { entries.values.filter { $0.phase == .working }.count }
    public var waiting: Int { entries.values.filter { $0.phase == .waiting }.count }
    /// Applies one event; true when it means a session has just finished answering.
    @discardableResult public mutating func apply(_ event: ClaudeEvent, at now: Date = Date()) -> Bool {
        switch event.kind {
        case .prompt, .tool, .toolFailure:
            entries[event.session] = Entry(phase: .working, seen: now)
        case .attention:
            // "Idle" and sign-in notices are not requests; an untyped notice only counts while an answer is under way.
            let blocking = event.detail == "permission_prompt" || event.detail == "elicitation_dialog"
            guard blocking || (event.detail == nil && entries[event.session] != nil) else { return false }
            entries[event.session] = Entry(phase: .waiting, seen: now)
        case .stop:
            entries.removeValue(forKey: event.session)
            return true
        case .end:
            entries.removeValue(forKey: event.session)
            helpers = helpers.filter { $0.value.session != event.session }
        case .subagentStart:
            guard let agent = event.agent else { return false }
            helpers[agent] = ClaudeSubagent(id: agent, type: event.agentType ?? "Agent", session: event.session, started: now)
        case .subagentStop:
            if let agent = event.agent { helpers.removeValue(forKey: agent) }
        }
        return false
    }
    public mutating func prune(at now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.seen) < ($0.value.phase == .working ? Self.workingLimit : Self.waitingLimit) }
        helpers = helpers.filter { now.timeIntervalSince($0.value.started) < Self.subagentLimit }
    }
}

/// What Claude Code asks before using a tool, reduced to what a person needs to decide. It travels from the
/// hook to the app over a private socket and is never written to disk.
public struct ClaudePermissionRequest: Codable, Equatable, Sendable {
    /// Claude Code and Codex ask the same question in the same words; only the name on the card differs.
    public enum Agent: String, Codable, Sendable { case claude, codex }
    public var agent = Agent.claude
    public var session: String
    public var tool: String
    /// The command, the file or the address the tool would act on.
    public var summary: String
    /// Claude's own one-line description of a command, when it gives one.
    public var note: String?
    /// Name of the folder the session works in.
    public var project: String?
    public init(agent: Agent = .claude, session: String, tool: String, summary: String, note: String? = nil, project: String? = nil) {
        self.agent = agent; self.session = session; self.tool = tool; self.summary = summary; self.note = note; self.project = project
    }
    /// Reads the JSON a `PermissionRequest` hook receives on its standard input.
    public static func parse(_ data: Data, agent: Agent = .claude) -> ClaudePermissionRequest? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["hook_event_name"] as? String == "PermissionRequest",
              let session = root["session_id"] as? String, !session.isEmpty, session.count <= 200,
              let tool = root["tool_name"] as? String, !tool.isEmpty, tool.count <= 200 else { return nil }
        let input = root["tool_input"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let subject = text("command") ?? text("file_path") ?? text("notebook_path") ?? text("url") ?? text("query") ?? text("pattern") ?? text("path")
            ?? input.keys.sorted().lazy.compactMap { text($0) }.first ?? ""
        let project = (root["cwd"] as? String).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        return ClaudePermissionRequest(agent: agent, session: session, tool: tool, summary: clipped(subject, to: 600), note: text("description").map { clipped($0, to: 200) },
                                       project: project.map { clipped($0, to: 80) })
    }
    private static func clipped(_ text: String, to limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
    /// Tool name as a person reads it: "mcp__github__create_issue" becomes "github · create_issue".
    public var toolTitle: String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? parts[0] + " · " + parts.dropFirst().joined(separator: "__") : tool
    }
}

/// The answer given in the notch. `pass` leaves the question to Claude Code's own prompt.
public enum ClaudePermissionAnswer: String, Sendable {
    case allow, deny, pass
    /// What the hook prints for Claude Code; nil prints nothing, which leaves the normal prompt in charge.
    public func hookOutput(denyMessage: String) -> Data? {
        guard self != .pass else { return nil }
        var decision: [String: Any] = ["behavior": rawValue]
        if self == .deny { decision["message"] = denyMessage }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision] as [String: Any]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

/// Recognises a finished download from the renames a browser makes in the Downloads folder,
/// without ever reading the folder itself.
public enum DownloadWatch {
    private static let partial: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]
    static func isPartial(_ path: String) -> Bool {
        path.split(separator: "/").contains { partial.contains(($0 as NSString).pathExtension.lowercased()) }
    }
    /// `renamed` holds the paths renamed in one batch of file events. A download is finished when a partial
    /// file was renamed and a regular file appeared directly in `folder` in the same batch.
    public static func finished(renamed: [String], folder: String) -> String? {
        let root = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        guard renamed.contains(where: isPartial) else { return nil }
        return renamed.last { path in
            let name = (path as NSString).lastPathComponent
            return (path as NSString).deletingLastPathComponent == root && !name.hasPrefix(".") && !isPartial(path)
        }
    }
}

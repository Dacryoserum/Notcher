import Foundation

/// What a Claude Code hook reports, reduced to the fields Notcher uses. Nothing of the conversation is kept.
public struct ClaudeEvent: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case prompt = "UserPromptSubmit", tool = "PostToolUse", attention = "Notification", stop = "Stop", end = "SessionEnd"
    }
    public var kind: Kind
    public var session: String
    /// Notification type ("permission_prompt", "idle_prompt"…) when Claude Code gives one.
    public var detail: String?
    public init(kind: Kind, session: String, detail: String? = nil) { self.kind = kind; self.session = session; self.detail = detail }
    /// Reads the JSON a hook receives on its standard input.
    public static func parse(_ data: Data) -> ClaudeEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["hook_event_name"] as? String, let kind = Kind(rawValue: name),
              let session = root["session_id"] as? String, !session.isEmpty, session.count <= 200 else { return nil }
        return ClaudeEvent(kind: kind, session: session, detail: root["notification_type"] as? String)
    }
}

/// Which Claude Code sessions are answering and which are waiting for the user, rebuilt from hook events.
public struct ClaudeSessions: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case working, waiting }
    private struct Entry: Equatable, Sendable { var phase: Phase; var seen: Date }
    private var entries: [String: Entry] = [:]
    /// An interrupted answer sends no event: a session silent for this long is no longer counted as working.
    public static let workingLimit: TimeInterval = 15 * 60
    public static let waitingLimit: TimeInterval = 2 * 3600
    public init() {}
    public var working: Int { entries.values.filter { $0.phase == .working }.count }
    public var waiting: Int { entries.values.filter { $0.phase == .waiting }.count }
    /// Applies one event; true when it means a session has just finished answering.
    @discardableResult public mutating func apply(_ event: ClaudeEvent, at now: Date = Date()) -> Bool {
        switch event.kind {
        case .prompt, .tool:
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
        }
        return false
    }
    public mutating func prune(at now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.seen) < ($0.value.phase == .working ? Self.workingLimit : Self.waitingLimit) }
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

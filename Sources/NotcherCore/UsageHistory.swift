import Foundation

/// One answer of an agent, as its local log records it: when, how many tokens, in which session.
/// Nothing of the conversation is kept.
public struct UsageRecord: Equatable, Sendable {
    public var date: Date
    public var tokens: Int
    public var session: String
    public var model: String?
    /// The same answer can be written several times (one line per block); this tells the copies apart.
    public var key: String?
    public init(date: Date, tokens: Int, session: String, model: String? = nil, key: String? = nil) {
        self.date = date; self.tokens = tokens; self.session = session; self.model = model; self.key = key
    }
}

public struct UsageDay: Equatable, Sendable, Identifiable {
    public var day: Date
    public var tokens: Int
    public var id: Date { day }
}

/// What the Agents page shows about the last days: tokens per day and a few counts.
public struct UsageHistory: Equatable, Sendable {
    /// Oldest first, one entry per calendar day, today last; days without use count zero.
    public var days: [UsageDay]
    public var total: Int
    public var sessions: Int
    public var activeDays: Int
    /// Consecutive days of use up to today (or up to yesterday when today has nothing yet).
    public var streak: Int
    public var favoriteModel: String?
    public var today: Int { days.last?.tokens ?? 0 }

    public init(records: [UsageRecord], days count: Int = 30, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        var seen = Set<String>(), perDay: [Date: Int] = [:], sessions = Set<String>(), models: [String: Int] = [:]
        for record in records where record.date >= first && record.date <= now.addingTimeInterval(60) && record.tokens > 0 {
            if let key = record.key { guard seen.insert(key).inserted else { continue } }
            perDay[calendar.startOfDay(for: record.date), default: 0] += record.tokens
            sessions.insert(record.session)
            if let model = record.model, !model.isEmpty, !model.hasPrefix("<") { models[model, default: 0] += record.tokens }
        }
        days = (0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map { UsageDay(day: $0, tokens: perDay[$0] ?? 0) }
        }
        total = days.reduce(0) { $0 + $1.tokens }
        self.sessions = sessions.count
        activeDays = days.filter { $0.tokens > 0 }.count
        var run = 0
        for day in days.reversed().drop(while: { $0.day == today && $0.tokens == 0 }) {
            guard day.tokens > 0 else { break }
            run += 1
        }
        streak = run
        favoriteModel = models.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// "12,4 M", "830 k": tokens as a person reads them.
    public static func short(_ tokens: Int, locale: Locale = .current) -> String {
        let value = Double(tokens)
        func format(_ number: Double, _ unit: String) -> String {
            let formatter = NumberFormatter()
            formatter.locale = locale; formatter.maximumFractionDigits = number < 10 ? 1 : 0; formatter.minimumFractionDigits = 0
            return (formatter.string(from: NSNumber(value: number)) ?? String(number)) + " " + unit
        }
        if value >= 1_000_000_000 { return format(value / 1_000_000_000, "G") }
        if value >= 1_000_000 { return format(value / 1_000_000, "M") }
        if value >= 1_000 { return format(value / 1_000, "k") }
        return String(tokens)
    }
}

/// Reads the lines of the logs Claude Code and Codex keep on this Mac.
public enum UsageLog {
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let plainStamp = ISO8601DateFormatter()
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return stamp.date(from: text) ?? plainStamp.date(from: text)
    }
    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// A line of `~/.claude/projects/…/*.jsonl`. Every token the model handled counts, cache included.
    public static func claude(_ line: Data) -> UsageRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any], root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
              let date = date(root["timestamp"]) else { return nil }
        let tokens = int(usage["input_tokens"]) + int(usage["output_tokens"]) + int(usage["cache_creation_input_tokens"]) + int(usage["cache_read_input_tokens"])
        let id = (message["id"] as? String).map { $0 + ":" + ((root["requestId"] as? String) ?? "") }
        return UsageRecord(date: date, tokens: tokens, session: root["sessionId"] as? String ?? "", model: message["model"] as? String, key: id)
    }
    /// A line of `~/.codex/sessions/…/*.jsonl`: each `token_count` event carries the tokens of the last turn.
    public static func codex(_ line: Data, session: String) -> UsageRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let last = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any], let date = date(root["timestamp"]) else { return nil }
        let total = int(last["total_tokens"])
        return UsageRecord(date: date, tokens: total > 0 ? total : int(last["input_tokens"]) + int(last["output_tokens"]), session: session)
    }
}

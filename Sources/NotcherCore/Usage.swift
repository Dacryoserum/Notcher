import Foundation
import CoreFoundation

public struct UsageWindow: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.id = id; self.title = title
        self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }

    public var fraction: Double { min(1, max(0, usedPercent / 100)) }
    public func isExpired(at date: Date = Date()) -> Bool { resetsAt.map { $0 <= date } ?? false }
}

public struct AgentUsage: Equatable {
    public var provider: String
    public var windows: [UsageWindow]
    public var model: String?
    public var contextPercent: Double?
    public var sessionCost: Double?
    public var capturedAt: Date
    public init(provider: String, windows: [UsageWindow] = [], model: String? = nil,
                contextPercent: Double? = nil, sessionCost: Double? = nil, capturedAt: Date = Date()) {
        self.provider = provider; self.windows = windows; self.model = model
        self.contextPercent = contextPercent; self.sessionCost = sessionCost; self.capturedAt = capturedAt
    }
    public func isStale(at date: Date = Date()) -> Bool { date.timeIntervalSince(capturedAt) > 600 }
}

public enum UsageParser {
    public static func claude(_ data: Data, capturedAt: Date = Date()) throws -> AgentUsage {
        let root = try object(data)
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        let windows = [("five_hour", "5 heures"), ("seven_day", "7 jours"), ("spend_limit", "Dépenses")].compactMap { key, title -> UsageWindow? in
            guard let item = limits[key] as? [String: Any], let percent = number(item["used_percentage"]), percent >= 0 else { return nil }
            return UsageWindow(id: key, title: title, usedPercent: percent, resetsAt: epoch(item["resets_at"]))
        }
        return AgentUsage(provider: "Claude Code", windows: windows,
                          model: (root["model"] as? [String: Any])?["display_name"] as? String,
                          contextPercent: number((root["context_window"] as? [String: Any])?["used_percentage"]),
                          sessionCost: number((root["cost"] as? [String: Any])?["total_cost_usd"]),
                          capturedAt: epoch(root["captured_at"]) ?? capturedAt)
    }

    public static func codex(_ data: Data, capturedAt: Date = Date()) throws -> AgentUsage {
        var root = try object(data)
        if let result = root["result"] as? [String: Any] { root = result }
        if let params = root["params"] as? [String: Any] { root = params }
        // Use the Codex bucket explicitly; never substitute another model's quota.
        let buckets = root["rateLimitsByLimitId"] as? [String: Any]
        let legacy = root["rateLimits"] as? [String: Any] ?? [:]
        let legacyIsCodex = legacy["limitId"] == nil || legacy["limitId"] as? String == "codex"
        let limits = (buckets?["codex"] as? [String: Any]) ?? (legacyIsCodex ? legacy : [:])
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let item = limits[key] as? [String: Any], let percent = number(item["usedPercent"]), percent >= 0 else { return nil }
            let minutes = number(item["windowDurationMins"])
            let title: String
            if let minutes, minutes >= 1440 { title = "\(Int(minutes / 1440)) jours" }
            else if let minutes, minutes >= 60 { title = "\(Int(minutes / 60)) heures" }
            else if let minutes { title = "\(Int(minutes)) min" }
            else { title = key == "primary" ? "Session" : "Semaine" }
            return UsageWindow(id: key, title: title, usedPercent: percent, resetsAt: epoch(item["resetsAt"]))
        }
        return AgentUsage(provider: "Codex", windows: windows, capturedAt: capturedAt)
    }

    public static func sanitizedClaudeSnapshot(_ data: Data, at date: Date = Date()) throws -> Data {
        let root = try object(data)
        var clean: [String: Any] = ["captured_at": date.timeIntervalSince1970]
        let allowed = ["model": ["display_name"], "context_window": ["used_percentage"], "cost": ["total_cost_usd"]]
        for (section, keys) in allowed {
            guard let input = root[section] as? [String: Any] else { continue }
            clean[section] = input.filter { keys.contains($0.key) }
        }
        if let limits = root["rate_limits"] as? [String: Any] {
            var windows: [String: Any] = [:]
            for key in ["five_hour", "seven_day", "spend_limit"] {
                if let item = limits[key] as? [String: Any] {
                    windows[key] = item.filter { ["used_percentage", "resets_at"].contains($0.key) }
                }
            }
            clean["rate_limits"] = windows
        }
        return try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dict
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func epoch(_ value: Any?) -> Date? { number(value).map(Date.init(timeIntervalSince1970:)) }
}

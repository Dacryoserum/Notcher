import Foundation
import NotcherCore

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Tokens per day for Claude Code and Codex, read from the logs both tools keep in the home folder.
/// Only files touched in the last month are opened, each one once until it changes.
@MainActor final class UsageStatsService: ObservableObject {
    @Published private(set) var claude: UsageHistory?
    @Published private(set) var codex: UsageHistory?
    @Published private(set) var loading = false
    private let reader = UsageLogReader()
    private var lastRead: [AgentKind: Date] = [:]

    func history(_ kind: AgentKind) -> UsageHistory? { kind == .claude ? claude : codex }
    /// Reads again unless it was done in the last minute.
    func refresh(_ kind: AgentKind, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRead[kind] ?? .distantPast) > 60 else { return }
        lastRead[kind] = Date(); loading = true
        let reader = reader
        Task {
            let value = await reader.history(kind)
            if kind == .claude { claude = value } else { codex = value }
            loading = false
        }
    }
}

/// Runs away from the interface: a month of logs can weigh hundreds of megabytes.
actor UsageLogReader {
    private struct Cached { var modified: Date; var size: Int; var records: [UsageRecord] }
    private var cache: [String: Cached] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func history(_ kind: AgentKind) -> UsageHistory {
        let root = kind == .claude ? home.appendingPathComponent(".claude/projects") : home.appendingPathComponent(".codex/sessions")
        let since = Date().addingTimeInterval(-31 * 86400)
        var records: [UsageRecord] = [], present = Set<String>()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since else { continue }
            let size = values.fileSize ?? 0
            present.insert(url.path)
            if let cached = cache[url.path], cached.modified == modified, cached.size == size { records += cached.records; continue }
            let read = Self.read(url, kind: kind)
            cache[url.path] = Cached(modified: modified, size: size, records: read)
            records += read
        }
        cache = cache.filter { present.contains($0.key) }
        return UsageHistory(records: records)
    }
    private static func read(_ url: URL, kind: AgentKind) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        // Most lines are text and tool calls: only those that can hold a count are decoded.
        let marker = Data((kind == .claude ? "\"usage\"" : "\"token_count\"").utf8)
        let session = url.deletingPathExtension().lastPathComponent
        var records: [UsageRecord] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            let line = data[start..<end]
            if line.count < 2_000_000, line.range(of: marker) != nil {
                let record = kind == .claude ? UsageLog.claude(Data(line)) : UsageLog.codex(Data(line), session: session)
                if let record { records.append(record) }
            }
            start = end < data.endIndex ? data.index(after: end) : end
        }
        return records
    }
}

import AppKit
import CoreServices
import UniformTypeIdentifiers
import NotcherCore

/// Carries a Claude Code hook event from the short-lived hook process to the running app.
enum ClaudeRelay {
    static let name = Notification.Name("fr.notcher.claude-event")
    static func post(_ event: ClaudeEvent) {
        var info = ["kind": event.kind.rawValue, "session": event.session]
        if let detail = event.detail { info["detail"] = detail }
        if let agent = event.agent { info["agent"] = agent }
        if let type = event.agentType { info["agentType"] = type }
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }
    static func event(from info: [AnyHashable: Any]?) -> ClaudeEvent? {
        guard let raw = info?["kind"] as? String, let kind = ClaudeEvent.Kind(rawValue: raw),
              let session = info?["session"] as? String, !session.isEmpty else { return nil }
        return ClaudeEvent(kind: kind, session: session, detail: info?["detail"] as? String, agent: info?["agent"] as? String, agentType: info?["agentType"] as? String)
    }
}

/// Claude's own icon, read from the app installed on this Mac. The picture belongs to Anthropic and is
/// never shipped with Notcher; without the app a symbol is used instead.
@MainActor enum ClaudeMark {
    private static var cached: NSImage??
    static var icon: NSImage? {
        if let cached { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop").map { NSWorkspace.shared.icon(forFile: $0.path) }
        cached = .some(image)
        return image
    }
}

/// Reports files that finish downloading, from file-system events alone: the Downloads folder is never
/// opened or listed, so macOS has no permission to ask for.
@MainActor final class DownloadWatcher {
    var onFinished: ((String) -> Void)?
    private var stream: FSEventStreamRef?
    private var folder = ""
    func start() {
        guard stream == nil, let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        folder = url.resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let renamed = (0..<min(count, list.count)).filter { flags[$0] & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }.map { list[$0] }
            guard !renamed.isEmpty else { return }
            MainActor.assumeIsolated { Unmanaged<DownloadWatcher>.fromOpaque(info).takeUnretainedValue().received(renamed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return }
        stream = created
    }
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    private func received(_ renamed: [String]) {
        if let path = DownloadWatch.finished(renamed: renamed, folder: folder) { onFinished?(path) }
    }
    /// The icon macOS gives to files of this kind, without touching the file.
    static func icon(for path: String) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: (path as NSString).pathExtension) ?? .data)
    }
}

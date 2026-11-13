import AppKit
import NotcherCore
import Foundation

enum AppPaths {
    static let support: URL = {
        if let override = ProcessInfo.processInfo.environment["NOTCHER_DATA_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Notcher", isDirectory: true)
    }()
    static let integrations = support.appendingPathComponent("Integrations", isDirectory: true)
    static func prepare() throws {
        for path in [support, integrations] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

struct CommandOutput { var data: Data; var status: Int32; var text: String { String(decoding: data, as: UTF8.self) } }
enum CommandError: LocalizedError {
    case timeout, failed(String), unavailable
    var errorDescription: String? {
        switch self {
        case .timeout: return L("Le service n’a pas répondu à temps.")
        case .failed(let reason): return L(reason)
        case .unavailable: return L("Ce service n’est pas disponible sur ce Mac.")
        }
    }
}

/// Bounded process execution. Stdout is drained while the child runs, avoiding pipe deadlocks.
enum Command {
    static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 12) async throws -> CommandOutput {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let collector = DataCollector(limit: 4 * 1024 * 1024)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                collector.append(data)
                if data.isEmpty { handle.readabilityHandler = nil }
            }
            defer {
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                try await Task.sleep(for: .milliseconds(100))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if timedOut { throw CommandError.timeout }
            // A descendant may keep stdout open. Never wait indefinitely for pipe EOF.
            let drainDeadline = Date().addingTimeInterval(0.25)
            while !collector.reachedEOF && Date() < drainDeadline { try await Task.sleep(for: .milliseconds(5)) }
            try Task.checkCancellation()
            return CommandOutput(data: collector.value, status: process.terminationStatus)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

final class DataCollector: @unchecked Sendable {
    private var bytes = Data()
    private var eof = false
    private let lock = NSLock()
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; if data.isEmpty { eof = true }; bytes.append(data.prefix(max(0, limit - bytes.count))) }
    var reachedEOF: Bool { lock.lock(); defer { lock.unlock() }; return eof }
    var value: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

func copyToClipboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func clockString(_ interval: TimeInterval) -> String {
    let seconds = Int(max(0, interval.isFinite ? interval : 0))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

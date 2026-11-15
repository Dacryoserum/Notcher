import Foundation
import NotcherCore

/// The private channel between Claude Code's permission hook and the running app: a Unix socket in
/// Notcher's own folder, readable by this user only. The hook sends one request and waits on the same
/// connection for the answer, so a question never outlives the process that asked it.
enum PermissionChannel {
    static var path: String { AppPaths.integrations.appendingPathComponent("permission.sock").path }

    fileprivate static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // The system limits socket paths to about a hundred bytes.
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    fileprivate static func open() -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        // A peer that left must produce an error, never a signal that kills the process.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }
    fileprivate static func write(_ data: Data, to descriptor: Int32) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { bytes in
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if count > 0 { sent += count } else if errno != EINTR && errno != EAGAIN { return false }
            }
            return true
        }
    }

    /// Hook side: asks the app and blocks until it answers. Nil when Notcher is not running or went away,
    /// which leaves Claude Code's own prompt in charge.
    static func ask(_ request: ClaudePermissionRequest, path: String = path) -> ClaudePermissionAnswer? {
        guard var address = address(path), let descriptor = open() else { return nil }
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, var message = try? JSONEncoder().encode(request) else { return nil }
        message.append(10)
        guard write(message, to: descriptor) else { return nil }
        var reply = Data(), buffer = [UInt8](repeating: 0, count: 64)
        while reply.count < 64, !reply.contains(10) {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { reply.append(contentsOf: buffer[0..<count]) } else if count == 0 || errno != EINTR { break }
        }
        return String(data: reply, encoding: .utf8).flatMap { ClaudePermissionAnswer(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// App side of the channel. Each connection carries one question; closing it without an answer hands the
/// question back to Claude Code.
@MainActor final class PermissionServer {
    /// A question arrived. Answer it with `reply`, or it stays open until its hook gives up.
    var onRequest: ((UUID, ClaudePermissionRequest) -> Void)?
    /// The hook left before an answer: the question was settled elsewhere (in the terminal) or cancelled.
    var onGone: ((UUID) -> Void)?
    private struct Client { let descriptor: Int32; let source: DispatchSourceRead; var buffer = Data(); var asked = false }
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [UUID: Client] = [:]
    private var path = ""

    func start(path: String = PermissionChannel.path) throws {
        guard source == nil else { return }
        guard var address = PermissionChannel.address(path), let descriptor = PermissionChannel.open() else { throw CommandError.unavailable }
        // A socket left by a previous run would refuse the name.
        unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptor); unlink(path); throw CommandError.unavailable
        }
        listener = descriptor; self.path = path
        let accepting = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        accepting.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        accepting.resume(); source = accepting
    }
    func stop() {
        for id in Array(clients.keys) { drop(id) }
        source?.cancel(); source = nil
        if listener >= 0 { close(listener); listener = -1; unlink(path) }
    }
    func reply(_ id: UUID, _ answer: ClaudePermissionAnswer) {
        guard let client = clients[id] else { return }
        _ = PermissionChannel.write(Data((answer.rawValue + "\n").utf8), to: client.descriptor)
        drop(id)
    }
    private func accept() {
        while true {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            guard clients.count < 32 else { close(descriptor); continue }
            let id = UUID()
            let reading = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
            reading.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.receive(id) } }
            clients[id] = Client(descriptor: descriptor, source: reading)
            reading.resume()
        }
    }
    private func receive(_ id: UUID) {
        guard var client = clients[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client.descriptor, &buffer, buffer.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else {
            let asked = client.asked
            drop(id)
            if asked { onGone?(id) }
            return
        }
        guard !client.asked else { return }
        client.buffer.append(contentsOf: buffer[0..<count])
        guard client.buffer.count <= 65_536 else { drop(id); return }
        guard let newline = client.buffer.firstIndex(of: 10) else { clients[id] = client; return }
        guard let request = try? JSONDecoder().decode(ClaudePermissionRequest.self, from: client.buffer.subdata(in: client.buffer.startIndex..<newline)) else { drop(id); return }
        client.asked = true; client.buffer.removeAll(); clients[id] = client
        onRequest?(id, request)
    }
    private func drop(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.source.cancel(); close(client.descriptor)
    }
}

/// A question from Claude Code waiting for an answer in the notch.
struct PendingPermission: Identifiable, Equatable {
    let id: UUID
    let request: ClaudePermissionRequest
    let received: Date
}

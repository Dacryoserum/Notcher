import AppKit
import NotcherCore

struct NowPlaying: Decodable, Sendable, Equatable {
    var title: String
    var artist: String
    var album: String
    var application: String
    var bundleIdentifier: String
    var playing: Bool
    var duration: Double
    var elapsed: Double
    var artwork: String?
    /// HTTPS address of the cover, when the player publishes one with the track.
    var artworkURL: String? = nil

    /// Players occasionally publish NaN, infinite or negative times; none may reach a slider.
    var sanitized: NowPlaying {
        var copy = self
        copy.duration = duration.isFinite ? max(0, duration) : 0
        copy.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        if copy.duration > 0 { copy.elapsed = min(copy.elapsed, copy.duration) }
        return copy
    }
}

struct MediaCommand: Sendable, Equatable {
    let action: String
    let value: Double?
    let spotify: Bool
}

struct MediaClient: Sendable {
    var readSystem: @Sendable () async throws -> NowPlaying?
    var readSpotify: @Sendable () async throws -> NowPlaying?
    var send: @Sendable (MediaCommand) async throws -> Void
    static let live = MediaClient(
        readSystem: { try await snapshot(["read"]) },
        readSpotify: { try await snapshot(["spotify-state"]) },
        send: { command in
            var arguments = command.spotify ? ["spotify-command", command.action] : [command.action]
            if let value = command.value { arguments.append(String(value)) }
            _ = try await run(arguments)
        }
    )
    private static func run(_ arguments: [String]) async throws -> CommandOutput {
        guard let script = Bundle.main.url(forResource: "MediaBridge", withExtension: "js") ?? Bundle.module.url(forResource: "MediaBridge", withExtension: "js") else { throw CommandError.unavailable }
        let result = try await Command.run("/usr/bin/osascript", ["-l", "JavaScript", script.path] + arguments, timeout: 4)
        guard result.status == 0 else { throw CommandError.failed("Le lecteur ne répond pas.") }
        if let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any], object["error"] != nil {
            throw CommandError.failed(arguments.first?.hasPrefix("spotify") == true ? "Spotify inaccessible. Vérifie son autorisation dans Réglages Système → Confidentialité → Automatisation." : "La lecture système est indisponible.")
        }
        return result
    }
    private static func snapshot(_ arguments: [String]) async throws -> NowPlaying? {
        let result = try await run(arguments)
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return nil }
        return try JSONDecoder().decode(NowPlaying.self, from: result.data).sanitized
    }
}

@MainActor final class MediaService: ObservableObject {
    @Published private(set) var track: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var error: String?
    @Published private(set) var available = true
    /// True once a paused player has been idle long enough to give the closed notch back.
    @Published private(set) var resting = false
    /// Minutes of pause before `resting`; 0 keeps the track in the notch forever.
    var restMinutes = 5 { didSet { updateRest() } }
    private var pausedSince: TimeInterval?
    /// What the closed notch should show: nothing for a player that has been paused for a long time.
    var compactTrack: NowPlaying? { resting ? nil : track }
    private let client: MediaClient
    private let now: @Sendable () -> TimeInterval
    private let artworkService: ArtworkService
    private var timer: Timer?
    private var spotifyObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var polling = false
    private var refreshQueued = false
    private var idleTicks = 0
    private var followUp: Task<Void, Never>?
    /// True while the panel is open: the display is then refreshed every second whatever the state.
    var attentive = false { didSet { if attentive && !oldValue { requestRefresh() } } }
    private var sampledAt: TimeInterval = 0
    private var lastSystemRead = -Double.infinity
    private var enabled = true
    private var revision = 0
    private var generation = UUID()
    private var failureCount = 0
    /// Cover that macOS itself holds for the current Spotify track: a second source when Spotify gives no address.
    private var systemCover: (key: NowPlaying.ArtworkKey, data: String)?
    private struct Intent {
        let command: MediaCommand
        let revision: Int
        let key: NowPlaying.ArtworkKey
        let previous: NowPlaying
        let sampledAt: TimeInterval
    }
    private var pending: [Intent] = []

    init(client: MediaClient = .live, artworkClient: ArtworkClient = .live, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.client = client; self.now = now
        artworkService = ArtworkService(client: artworkClient)
        artworkService.onChange = { [weak self] in self?.artwork = $0 }
    }
    func start() {
        guard timer == nil else { return }
        requestRefresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        spotifyObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.spotify.client.PlaybackState"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let spotifyObserver { DistributedNotificationCenter.default().removeObserver(spotifyObserver) }; spotifyObserver = nil
        setEnabled(false)
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        generation = UUID(); revision += 1; enabled = value
        pollTask?.cancel(); pollTask = nil; commandTask?.cancel(); commandTask = nil; pending.removeAll()
        followUp?.cancel(); followUp = nil; refreshQueued = false
        if !value { track = nil; artworkService.clear(); error = nil; updateRest() }
        else { lastSystemRead = -.infinity; requestRefresh() }
    }
    var elapsed: Double {
        guard let track else { return 0 }
        // Never extrapolate forever if a reader hangs or stops publishing.
        let delta = track.playing ? min(track.isSpotify ? 2 : 4, max(0, now() - sampledAt)) : 0
        return max(0, min(track.duration > 0 ? track.duration : .greatestFiniteMagnitude, track.elapsed + delta))
    }
    /// Each poll starts a short-lived process: a closed, silent notch is read less often.
    private func updateRest() {
        if track == nil || track?.playing == true { pausedSince = nil }
        else if pausedSince == nil { pausedSince = now() }
        let value = pausedSince.map { MediaRest.isResting(pausedFor: now() - $0, limitMinutes: restMinutes) } ?? false
        if resting != value { resting = value }
    }
    private func tick() {
        updateRest()
        idleTicks += 1
        let interval = attentive || track?.playing == true ? 1 : track == nil ? 3 : 2
        if idleTicks >= interval { requestRefresh() }
    }
    private func requestRefresh() {
        guard enabled, commandTask == nil else { return }
        // A change announced during a read is not lost: one more read follows it.
        guard pollTask == nil else { refreshQueued = true; return }
        idleTicks = 0; refreshQueued = false
        let token = generation
        pollTask = Task { [weak self] in
            await self?.refresh()
            guard let self, self.generation == token else { return }
            self.pollTask = nil
            if self.refreshQueued { self.requestRefresh() }
        }
    }
    /// A player needs a moment to switch tracks; read again shortly instead of waiting for the next tick.
    private func refreshSoon() {
        followUp?.cancel()
        let token = generation
        followUp = Task { [weak self] in
            for delay in [350, 900] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, self.generation == token else { return }
                self.requestRefresh()
            }
        }
    }
    func refresh() async {
        guard enabled, !polling, commandTask == nil else { return }
        let token = generation, version = revision
        polling = true
        defer { polling = false }
        do {
            let value: NowPlaying?
            if track?.isSpotify == true, now() - lastSystemRead < 3 {
                value = try await client.readSpotify()
            } else {
                let system = try await client.readSystem()
                lastSystemRead = now()
                if system?.isSpotify == true || (system == nil && track?.isSpotify == true) {
                    if let system, let cover = system.artwork, !cover.isEmpty { systemCover = (system.artworkKey, cover) }
                    value = try await client.readSpotify()
                } else { value = system }
            }
            guard enabled, token == generation, version == revision, commandTask == nil, !Task.isCancelled else { return }
            apply(value)
        } catch {
            guard enabled, token == generation, version == revision, !Task.isCancelled else { return }
            failureCount += 1; self.error = error.localizedDescription
            if failureCount >= 3 { available = false; track = nil; artworkService.clear() }
        }
    }
    private func apply(_ read: NowPlaying?) {
        var value = read
        if let current = value, current.isSpotify, current.artwork == nil, let cover = systemCover,
           cover.key.title == current.title, cover.key.artist == current.artist { value?.artwork = cover.data }
        sampledAt = now(); error = nil; available = true; failureCount = 0
        // Another song while paused means someone is using the player: the pause starts over.
        if track?.artworkKey != value?.artworkKey { pausedSince = nil }
        if track != value { track = value }
        if let value { artworkService.update(value) } else { artworkService.clear() }
        updateRest()
    }
    func command(_ action: String, value: Double? = nil) {
        guard enabled, var current = track else { return }
        let previous = current, previousTime = sampledAt
        let resolved = action == "toggle" ? (current.playing ? "pause" : "play") : action
        guard ["play", "pause", "next", "previous", "seek"].contains(resolved) else { return }
        let position = value.map { max(0, min($0.isFinite ? $0 : 0, current.duration > 0 ? current.duration : .greatestFiniteMagnitude)) }
        revision += 1
        let command = MediaCommand(action: resolved, value: position, spotify: current.isSpotify)
        // Capture the current position before freezing/resuming the optimistic UI.
        current.elapsed = elapsed
        if resolved == "play" || resolved == "pause" { current.playing = resolved == "play" }
        if resolved == "seek", let position { current.elapsed = position }
        sampledAt = now(); track = current
        pausedSince = nil; updateRest()
        // Rapid toggles/slider moves keep the last intent; next/previous remain ordered.
        if ["play", "pause", "seek"].contains(resolved), let last = pending.last,
           last.key == current.artworkKey,
           (resolved == "seek" ? last.command.action == "seek" : ["play", "pause"].contains(last.command.action)) { pending.removeLast() }
        pending.append(Intent(command: command, revision: revision, key: current.artworkKey, previous: previous, sampledAt: previousTime))
        guard commandTask == nil else { return }
        let token = generation
        commandTask = Task { [weak self] in await self?.drainCommands(generation: token) }
    }
    private func drainCommands(generation token: UUID) async {
        var trackChanged = false
        defer { if generation == token { commandTask = nil; if trackChanged { refreshSoon() } } }
        while enabled, generation == token, !pending.isEmpty, !Task.isCancelled {
            let intent = pending.removeFirst()
            if ["next", "previous"].contains(intent.command.action) { trackChanged = true }
            guard track?.artworkKey == intent.key else { continue }
            do {
                try await client.send(intent.command)
                guard enabled, token == generation, !Task.isCancelled else { return }
                guard revision == intent.revision else { continue }
                // Confirm with the actual player, never with a stale MediaRemote playback rate.
                let value = try await (intent.command.spotify ? client.readSpotify() : client.readSystem())
                guard enabled, token == generation, revision == intent.revision, !Task.isCancelled else { continue }
                apply(value)
            } catch {
                guard enabled, token == generation, revision == intent.revision, !Task.isCancelled else { continue }
                track = intent.previous; sampledAt = intent.sampledAt
                self.error = error.localizedDescription
            }
        }
    }
    func openPlayer(_ bundle: String? = nil) {
        let identifier = bundle ?? track?.bundleIdentifier ?? "com.spotify.client"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { NSWorkspace.shared.open(url) }
    }
}

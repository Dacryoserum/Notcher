import AppKit
import NotcherCore
import ImageIO

struct SpotifyArtwork: Decodable, Sendable {
    let title: String
    let artist: String
    let album: String
    let url: String

    func matches(_ track: NowPlaying) -> Bool {
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased() }
        return normalized(title) == normalized(track.title) && normalized(artist) == normalized(track.artist)
            && (album.isEmpty || track.album.isEmpty || normalized(album) == normalized(track.album))
    }
}

struct ArtworkClient: Sendable {
    var fetch: @Sendable (NowPlaying) async throws -> Data?
    static let live = ArtworkClient { track in
        if track.isAppleMusic { return try await musicCover(track) }
        guard track.canRequestSpotifyArtwork else { return nil }
        // Preferred: the address delivered with the track. The separate lookup remains for sources without one.
        if let url = track.remoteArtworkURL { return try await download(url) }
        guard let script = Bundle.main.url(forResource: "MediaBridge", withExtension: "js") ?? Bundle.module.url(forResource: "MediaBridge", withExtension: "js") else { return nil }
        let result = try await Command.run("/usr/bin/osascript", ["-l", "JavaScript", script.path, "spotify-artwork"], timeout: 6)
        guard result.status == 0, result.text.trimmingCharacters(in: .whitespacesAndNewlines) != "null" else { return nil }
        let value = try JSONDecoder().decode(SpotifyArtwork.self, from: result.data)
        var described = track; described.artworkURL = value.url
        guard value.matches(track), let url = described.remoteArtworkURL else { return nil }
        return try await download(url)
    }
    /// Music hands the cover of its current track to a script. The title is checked inside the same
    /// script, so the picture can never belong to the song before or after.
    private static let musicScript = """
        on run argv
            set wanted to item 1 of argv
            set target to item 2 of argv
            tell application id "com.apple.Music"
                if not running then return "none"
                set playingNow to current track
                if (name of playingNow) is not wanted then return "none"
                if (count of artworks of playingNow) is 0 then return "none"
                set bytes to raw data of artwork 1 of playingNow
            end tell
            set handle to open for access (POSIX file target) with write permission
            try
                set eof handle to 0
                write bytes to handle
                close access handle
            on error
                close access handle
                return "none"
            end try
            return "ok"
        end run
        """
    private static func musicCover(_ track: NowPlaying) async throws -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-cover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await Command.run("/usr/bin/osascript", ["-e", musicScript, track.title, file.path], timeout: 6)
        guard result.status == 0, result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 12_000_000 else { return nil }
        return try Data(contentsOf: file)
    }
    private static func download(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 6_000_000,
              response.mimeType?.hasPrefix("image/") == true else { return nil }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        // Bound unknown/chunked responses too; a bad URL must not grow memory indefinitely.
        for try await byte in bytes {
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            guard data.count < 6_000_000 else { return nil }
            data.append(byte)
        }
        return data
    }
}

@MainActor final class ArtworkService {
    private(set) var image: NSImage?
    var onChange: ((NSImage?) -> Void)?
    private let client: ArtworkClient
    private let retryDelays: [TimeInterval]
    private var task: Task<Void, Never>?
    private var key: NowPlaying.ArtworkKey?
    private var requestID = UUID()
    private var embedded: String?
    /// Address of the cover being shown or loaded, and the last one asked for.
    private var shownSource: String?
    private var requestedSource: String?
    private var retryAfter = Date.distantPast
    private var attempts = 0
    private struct Cached { let image: NSImage; let source: String? }
    private var cache: [NowPlaying.ArtworkKey: Cached] = [:]
    private var cacheOrder: [NowPlaying.ArtworkKey] = []

    /// A player that just changed track may not expose its cover yet: retry quickly first, then back off.
    init(client: ArtworkClient = .live, retryDelays: [TimeInterval] = [0.6, 1.5, 3, 6, 12, 20]) {
        self.client = client; self.retryDelays = retryDelays
    }
    func clear() {
        task?.cancel(); task = nil; requestID = UUID(); key = nil; embedded = nil
        shownSource = nil; requestedSource = nil
        attempts = 0; retryAfter = .distantPast; publish(nil)
    }
    func update(_ track: NowPlaying) {
        let newKey = track.artworkKey
        if key != newKey {
            clear(); key = newKey
            if let cached = cache[newKey] { shownSource = cached.source; publish(cached.image) }
        }
        let supplied = track.artwork.flatMap { $0.isEmpty ? nil : $0 }
        if let supplied, supplied != embedded, let data = Data(base64Encoded: supplied), data.count <= 6_000_000 {
            embedded = supplied
            task?.cancel(); task = nil
            load(key: newKey, source: nil) { data }
            return
        }
        guard embedded == nil, track.canRequestSpotifyArtwork || track.isAppleMusic else { return }
        let remote = track.remoteArtworkURL?.absoluteString
        // The player corrected the address after the track changed: the earlier answer no longer counts.
        if let remote, remote != requestedSource, remote != shownSource {
            task?.cancel(); task = nil
            attempts = 0; retryAfter = .distantPast
        }
        let missing = image == nil || (remote != nil && remote != shownSource)
        guard missing, task == nil, attempts < retryDelays.count, Date() >= retryAfter else { return }
        retryAfter = Date().addingTimeInterval(retryDelays[attempts])
        attempts += 1
        requestedSource = remote
        let client = client
        load(key: newKey, source: remote) { try await client.fetch(track) }
    }
    private func load(key: NowPlaying.ArtworkKey, source: String?, fetch: @escaping @Sendable () async throws -> Data?) {
        let id = UUID(); requestID = id
        task = Task { [weak self] in
            defer { if self?.requestID == id { self?.task = nil } }
            do {
                guard let data = try await fetch() else { return }
                try Task.checkCancellation()
                let bitmap = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }.value
                try Task.checkCancellation()
                guard let self, self.requestID == id, self.key == key, let bitmap else { return }
                let image = NSImage(cgImage: bitmap, size: .zero)
                self.cache[key] = Cached(image: image, source: source)
                self.cacheOrder.removeAll { $0 == key }; self.cacheOrder.append(key)
                if self.cacheOrder.count > 24 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
                self.shownSource = source
                self.publish(image)
            } catch { /* Artwork failures must never interrupt playback or the panel. */ }
        }
    }
    private func publish(_ value: NSImage?) {
        guard image !== value else { return }
        image = value; onChange?(value)
    }
}

extension NowPlaying {
    struct ArtworkKey: Hashable {
        let title: String
        let artist: String
        let album: String
        let source: String
    }
    var artworkKey: ArtworkKey { .init(title: title, artist: artist, album: album, source: bundleIdentifier.isEmpty ? application : bundleIdentifier) }
    var remoteArtworkURL: URL? {
        guard let artworkURL else { return nil }
        // The image host serves both schemes; only the secure one is ever requested.
        let secure = artworkURL.hasPrefix("http://") ? "https://" + artworkURL.dropFirst(7) : artworkURL
        guard let url = URL(string: secure), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
    var canRequestSpotifyArtwork: Bool { isSpotify || (bundleIdentifier.isEmpty && application.isEmpty) }
    var isAppleMusic: Bool { bundleIdentifier == "com.apple.Music" }
    var isSpotify: Bool { bundleIdentifier == "com.spotify.client" || (bundleIdentifier.isEmpty && application.localizedCaseInsensitiveContains("spotify")) }
}

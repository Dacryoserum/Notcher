import XCTest
import AppKit
@testable import Notcher

private actor CoverRequests {
    var count = 0
    var failures = 0
    var sources: [String?] = []
    func fetch(_ data: Data) async -> Data { count += 1; return data }
    /// Mimics a player whose cover is not available during the first moments of a new track.
    func fetch(_ data: Data, for track: NowPlaying) async -> Data? {
        count += 1; sources.append(track.artworkURL)
        if failures > 0 { failures -= 1; return nil }
        return data
    }
    func failNext(_ value: Int) { failures = value }
}

final class ArtworkTests: XCTestCase {
    // Valid local PNG; the tests never contact Spotify, MediaRemote or the network.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0N8AAAAASUVORK5CYII=")!
    private func track(_ title: String = "Track", artwork: String? = nil) -> NowPlaying {
        NowPlaying(title: title, artist: "Artist", album: "Album", application: "Spotify", bundleIdentifier: "com.spotify.client", playing: true, duration: 180, elapsed: 0, artwork: artwork)
    }
    @MainActor private func waitForImage(_ service: ArtworkService) async throws {
        let deadline = Date().addingTimeInterval(2)
        while service.image == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(service.image)
    }
    @MainActor func testMissingEmbeddedCoverKeepsFallbackAndDoesNotFetchAgain() async throws {
        let calls = CoverRequests(), data = png
        let service = ArtworkService(client: .init { _ in await calls.fetch(data) })
        service.update(track())
        try await waitForImage(service)
        let original = service.image
        for _ in 0..<10 { service.update(track()) }
        XCTAssertTrue(service.image === original)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }
    @MainActor func testLateOldCoverCannotOverwriteNewTrackOrDisabledService() async throws {
        let data = png
        let service = ArtworkService(client: .init { _ in
            // Simulate a transport that ignores cancellation, then returns late.
            try? await Task.sleep(for: .milliseconds(100))
            return data
        })
        service.update(track("Old"))
        await Task.yield()
        var next = track("New"); next.bundleIdentifier = "com.apple.Music"; next.application = "Music"
        service.update(next)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(service.image)
        service.update(track("Third")); await Task.yield(); service.clear()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(service.image)
    }
    @MainActor func testSameEmbeddedArtworkCanReturnAfterPlaybackDisappears() async throws {
        let service = ArtworkService(client: .init { _ in XCTFail("Unexpected network request"); return nil })
        let value = track(artwork: png.base64EncodedString())
        service.update(value); try await waitForImage(service)
        service.clear(); XCTAssertNil(service.image)
        service.update(value); try await waitForImage(service)
    }
    @MainActor func testTrackCacheAvoidsRedownloadingOnReturnAndSourceIsPartOfIdentity() async throws {
        let calls = CoverRequests(), data = png
        let service = ArtworkService(client: .init { _ in await calls.fetch(data) })
        service.update(track("A")); try await waitForImage(service)
        service.update(track("B")); try await waitForImage(service)
        service.update(track("A")); XCTAssertNotNil(service.image)
        let count = await calls.count; XCTAssertEqual(count, 2)
        var other = track("A"); other.bundleIdentifier = "another.player"; other.application = "Another"
        service.update(other); XCTAssertNil(service.image)
    }
    @MainActor func testCoverMissingRightAfterATrackChangeIsRetriedPromptly() async throws {
        let calls = CoverRequests(), data = png
        await calls.failNext(2)
        let service = ArtworkService(client: .init { await calls.fetch(data, for: $0) }, retryDelays: [0.02, 0.02, 0.02, 0.02])
        var next = track("Skipped from Notcher"); next.artworkURL = "https://example.com/new.jpg"
        let deadline = Date().addingTimeInterval(2)
        // The media service calls update at every poll; the cover must arrive without a new track change.
        while service.image == nil && Date() < deadline { service.update(next); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(service.image)
        let count = await calls.count
        XCTAssertEqual(count, 3)
        for _ in 0..<10 { service.update(next) }
        let final = await calls.count
        XCTAssertEqual(final, 3)
    }
    @MainActor func testRetriesStopAfterTheLastDelay() async throws {
        let calls = CoverRequests(), data = png
        await calls.failNext(100)
        let service = ArtworkService(client: .init { await calls.fetch(data, for: $0) }, retryDelays: [0.01, 0.01])
        for _ in 0..<30 { service.update(track()); try await Task.sleep(for: .milliseconds(5)) }
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertNil(service.image)
    }
    @MainActor func testCorrectedCoverAddressReplacesAStaleCover() async throws {
        let calls = CoverRequests(), data = png
        let service = ArtworkService(client: .init { await calls.fetch(data, for: $0) }, retryDelays: [0.01, 0.01, 0.01])
        var value = track(); value.artworkURL = "https://example.com/previous-track.jpg"
        service.update(value); try await waitForImage(service)
        let stale = service.image
        // Same song, but the player now reports the address of its real cover.
        value.artworkURL = "https://example.com/real.jpg"
        let deadline = Date().addingTimeInterval(2)
        while service.image === stale && Date() < deadline { service.update(value); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.image === stale)
        let sources = await calls.sources
        XCTAssertEqual(sources, ["https://example.com/previous-track.jpg", "https://example.com/real.jpg"])
        for _ in 0..<5 { service.update(value) }
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }
    func testOnlySecureCoverAddressesAreUsed() {
        var value = track()
        XCTAssertNil(value.remoteArtworkURL)
        value.artworkURL = "http://example.com/cover.jpg"; XCTAssertEqual(value.remoteArtworkURL?.scheme, "https")
        value.artworkURL = "file:///etc/passwd"; XCTAssertNil(value.remoteArtworkURL)
        value.artworkURL = "https://"; XCTAssertNil(value.remoteArtworkURL)
        value.artworkURL = "https://i.scdn.co/image/abc"; XCTAssertEqual(value.remoteArtworkURL?.host, "i.scdn.co")
    }
    func testUnusableTimesNeverReachTheInterface() throws {
        var value = track(); value.duration = .infinity; value.elapsed = .nan
        XCTAssertEqual(value.sanitized.duration, 0); XCTAssertEqual(value.sanitized.elapsed, 0)
        value.duration = 100; value.elapsed = 400
        XCTAssertEqual(value.sanitized.elapsed, 100)
        let old = Data(#"{"title":"T","artist":"A","album":"B","application":"Music","bundleIdentifier":"com.apple.Music","playing":true,"duration":10,"elapsed":1,"artwork":null}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(NowPlaying.self, from: old).artworkURL)
    }
    func testSpotifyMetadataMustMatchActiveTrack() {
        let same = SpotifyArtwork(title: " track ", artist: "ARTIST", album: "Album", url: "https://example.com/cover.jpg")
        XCTAssertTrue(same.matches(track()))
        XCTAssertFalse(same.matches(track("Different")))
        var differentArtist = track(); differentArtist.artist = "Other"
        XCTAssertFalse(same.matches(differentArtist))
        var differentAlbum = track(); differentAlbum.album = "Other"
        XCTAssertFalse(same.matches(differentAlbum))
    }
}

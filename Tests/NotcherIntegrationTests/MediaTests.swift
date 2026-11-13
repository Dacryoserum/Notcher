import XCTest
@testable import Notcher

private final class MediaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += seconds; lock.unlock() }
}

private actor FakePlayer {
    var snapshot = NowPlaying(title: "Track", artist: "Artist", album: "Album", application: "Spotify", bundleIdentifier: "com.spotify.client", playing: true, duration: 240, elapsed: 42, artwork: nil)
    var commands: [MediaCommand] = []
    var completedReads = 0
    var startedReads = 0
    var slowNextRead = false
    var failCommand = false
    var stopped = false
    var otherPlayer = false
    func system() -> NowPlaying? {
        if stopped { return nil }
        var stale = snapshot; stale.playing = true; stale.elapsed = 10
        if otherPlayer { stale.bundleIdentifier = "com.apple.Music"; stale.application = "Music"; stale.title = "Other" }
        return stale
    }
    func read() async throws -> NowPlaying? {
        startedReads += 1
        let captured = stopped ? nil : snapshot
        if slowNextRead { slowNextRead = false; try await Task.sleep(for: .milliseconds(180)) }
        completedReads += 1
        return captured
    }
    func send(_ command: MediaCommand) async throws {
        commands.append(command)
        try await Task.sleep(for: .milliseconds(30))
        if failCommand { throw CommandError.failed("Commande refusée") }
        if command.action == "pause" { snapshot.playing = false }
        if command.action == "play" { snapshot.playing = true }
        if let value = command.value, command.action == "seek" { snapshot.elapsed = value }
    }
    func setPlayback(_ playing: Bool, position: Double) { snapshot.playing = playing; snapshot.elapsed = position }
    func delayNextRead() { slowNextRead = true }
    func fail() { failCommand = true }
    func switchPlayer() { otherPlayer = true }
}

final class MediaTests: XCTestCase {
    @MainActor private func service(_ player: FakePlayer, _ clock: MediaTestClock) -> MediaService {
        MediaService(client: .init(readSystem: { await player.system() }, readSpotify: { try await player.read() }, send: { try await player.send($0) }), artworkClient: .init { _ in nil }, now: { clock.now() })
    }
    @MainActor private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = await condition(); XCTAssertTrue(result)
    }
    @MainActor func testSpotifyPauseOverridesStaleSystemPlaybackAndFreezesPosition() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await player.setPlayback(false, position: 42)
        await media.refresh()
        XCTAssertEqual(media.track?.playing, false)
        clock.advance(10)
        XCTAssertEqual(media.elapsed, 42)
        await player.setPlayback(true, position: 50)
        await media.refresh(); clock.advance(1)
        XCTAssertEqual(media.elapsed, 51)
        await player.setPlayback(false, position: 51)
        await media.refresh(); clock.advance(30)
        XCTAssertEqual(media.elapsed, 51)
        media.stop()
    }
    @MainActor func testPauseButtonFreezesImmediatelyThenConfirmsWithSpotify() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await media.refresh(); clock.advance(1)
        media.command("toggle")
        XCTAssertEqual(media.track?.playing, false)
        let paused = media.elapsed; clock.advance(1)
        XCTAssertEqual(media.elapsed, paused)
        try await waitFor { await player.completedReads >= 2 }
        let commands = await player.commands
        XCTAssertEqual(commands, [.init(action: "pause", value: nil, spotify: true)])
        clock.advance(10); XCTAssertEqual(media.elapsed, 42)
        media.stop()
    }
    @MainActor func testLatePlayingSnapshotCannotUndoPauseCommand() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await media.refresh()
        await player.delayNextRead()
        let oldRead = Task { await media.refresh() }
        try await waitFor { await player.startedReads >= 2 }
        media.command("toggle")
        await oldRead.value
        try await waitFor { await player.completedReads >= 3 }
        XCTAssertEqual(media.track?.playing, false)
        clock.advance(30); XCTAssertEqual(media.elapsed, 42)
        media.stop()
    }
    @MainActor func testRapidTogglesAreExplicitAndPreserveLastIntent() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await media.refresh()
        media.command("toggle"); media.command("toggle"); media.command("toggle")
        try await waitFor { await player.completedReads >= 2 }
        XCTAssertEqual(media.track?.playing, false)
        let commands = await player.commands
        XCTAssertFalse(commands.contains { $0.action == "toggle" })
        XCTAssertEqual(commands.last?.action, "pause")
        media.stop()
    }
    @MainActor func testRejectedCommandRestoresPlaybackAndReportsFailure() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await media.refresh(); await player.fail()
        media.command("toggle")
        try await waitFor { media.error != nil }
        XCTAssertEqual(media.track?.playing, true)
        media.stop()
    }
    @MainActor func testExtrapolationIsBoundedAndAnotherPlayerCanTakeOver() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await media.refresh(); clock.advance(60)
        XCTAssertLessThanOrEqual(media.elapsed, 44)
        await player.switchPlayer(); await media.refresh()
        XCTAssertEqual(media.track?.application, "Music")
        media.stop()
    }
    @MainActor func testLongPauseFreesTheClosedNotchUntilPlaybackOrACommandReturns() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        media.restMinutes = 5
        await player.setPlayback(false, position: 42)
        await media.refresh()
        XCTAssertFalse(media.resting); XCTAssertNotNil(media.compactTrack)
        clock.advance(299); await media.refresh()
        XCTAssertFalse(media.resting)
        clock.advance(2); await media.refresh()
        XCTAssertTrue(media.resting)
        XCTAssertNil(media.compactTrack)
        XCTAssertNotNil(media.track) // The open panel still shows what was playing.
        await player.setPlayback(true, position: 43); await media.refresh()
        XCTAssertFalse(media.resting)
        await player.setPlayback(false, position: 44); await media.refresh()
        clock.advance(600); await media.refresh()
        XCTAssertTrue(media.resting)
        media.command("toggle")
        XCTAssertFalse(media.resting)
        media.restMinutes = 0; clock.advance(100_000)
        XCTAssertFalse(media.resting)
        media.stop()
    }
    @MainActor func testDisableDuringPendingCommandCannotResurrectPlayback() async throws {
        let player = FakePlayer(), clock = MediaTestClock(), media = service(player, clock)
        await media.refresh(); media.command("toggle")
        try await waitFor { await !player.commands.isEmpty }
        media.setEnabled(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(media.track); XCTAssertNil(media.artwork)
    }
}

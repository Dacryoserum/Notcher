import XCTest
@testable import Notcher

private actor MockHardware {
    var calls = 0
    var fail = true
    func request(_ arguments: [String]) async throws -> Data {
        calls += 1
        try await Task.sleep(for: .milliseconds(80))
        if fail { throw CommandError.timeout }
        return Data(#"["Casque"]"#.utf8)
    }
    func recover() { fail = false }
}

final class ResilienceTests: XCTestCase {
    @MainActor func testBluetoothTimeoutLeavesMainActorResponsiveAndCanRetry() async throws {
        let driver = MockHardware()
        let service = BluetoothService(client: .init { try await driver.request($0) })
        for _ in 0..<20 { service.refresh() }
        XCTAssertTrue(service.loading)
        // This task and the UI share the main actor; a synchronous hardware query would block it.
        let marker = Task { @MainActor in 42 }
        let value = await marker.value
        XCTAssertEqual(value, 42)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(service.loading)
        XCTAssertNotNil(service.error)
        let firstCalls = await driver.calls
        XCTAssertEqual(firstCalls, 1)
        await driver.recover()
        service.refresh()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertNil(service.error)
        XCTAssertEqual(service.connected, ["Casque"])
    }
    @MainActor func testLeavingSystemCancelsBluetoothAndIgnoresLateResult() async throws {
        let driver = MockHardware(); await driver.recover()
        let service = BluetoothService(client: .init { try await driver.request($0) })
        service.refresh()
        await Task.yield()
        service.cancel()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(service.loading)
        XCTAssertTrue(service.connected.isEmpty)
        XCTAssertNil(service.error)
    }
    @MainActor func testHardwareFailureDoesNotInvalidateIndependentAudioRead() async throws {
        let client = HardwareClient { arguments in
            if arguments == ["audio"] { return try JSONEncoder().encode(AudioSnapshot(volume: 0.6, canSetVolume: true, outputName: "Test")) }
            try await Task.sleep(for: .milliseconds(60))
            throw CommandError.timeout
        }
        let service = SystemService(client: client)
        service.refresh(); service.refreshBrightness(); service.refreshOutputs()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(service.volume, 0.6)
        XCTAssertTrue(service.canSetVolume)
        XCTAssertFalse(service.canSetBrightness)
        XCTAssertNotNil(service.displayError)
        service.stop()
    }
    func testCancellingACommandDoesNotWaitForItsTimeout() async throws {
        let begin = Date()
        let task = Task { try await Command.run("/bin/sleep", ["30"], timeout: 30) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
    }
    func testIgnoredTerminationSignalStillHasABoundedTimeout() async throws {
        let begin = Date()
        do {
            _ = try await Command.run("/usr/bin/perl", ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30;"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is CommandError) }
        XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
    }
    func testInheritedOutputPipeCannotHangACompletedCommand() async throws {
        let begin = Date()
        let output = try await Command.run("/bin/sh", ["-c", "/bin/sleep 30 & printf '%s' \"$!\""], timeout: 2)
        guard let child = Int32(output.text) else { XCTFail("Missing child PID"); return }
        defer { kill(child, SIGTERM) }
        XCTAssertEqual(output.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
    }
}

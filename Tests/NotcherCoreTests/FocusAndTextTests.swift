import XCTest
@testable import NotcherCore

final class FocusAndTextTests: XCTestCase {
    func testTimerTracksWallClockAcrossSleepAndFinishesOnlyOnce() {
        var clock = FocusClock(duration: 60)
        clock.start(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(clock.remaining(at: Date(timeIntervalSince1970: 130)), 30)
        XCTAssertTrue(clock.finishIfNeeded(at: Date(timeIntervalSince1970: 5000)))
        XCTAssertFalse(clock.finishIfNeeded(at: Date(timeIntervalSince1970: 5001)))
        XCTAssertEqual(clock.remaining(), 0)
    }
    func testPauseResumeAndPersistence() throws {
        var clock = FocusClock(duration: 60)
        clock.start(at: Date(timeIntervalSince1970: 100))
        clock.pause(at: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(clock.remaining(at: Date(timeIntervalSince1970: 900)), 40)
        clock.start(at: Date(timeIntervalSince1970: 1000))
        let restored = try JSONDecoder().decode(FocusClock.self, from: JSONEncoder().encode(clock))
        XCTAssertEqual(restored.remaining(at: Date(timeIntervalSince1970: 1015)), 25)
    }
    func testRepeatedStartDoesNotExtendDeadline() {
        var clock = FocusClock(duration: 60)
        clock.start(at: Date(timeIntervalSince1970: 100))
        clock.start(at: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(clock.deadline, Date(timeIntervalSince1970: 160))
    }
    func testTextRoundTripsUnicode() throws {
        let text = "Bonjour, été 🌿 /?&=+"
        XCTAssertEqual(try TextOperation.decodeBase64.apply(to: TextOperation.encodeBase64.apply(to: text)), text)
        XCTAssertEqual(try TextOperation.decodeURL.apply(to: TextOperation.encodeURL.apply(to: text)), text)
        XCTAssertTrue(try TextOperation.encodeURL.apply(to: text).contains("%2B"))
    }
    func testBadInputDoesNotSilentlyProduceAnEmptyString() {
        XCTAssertThrowsError(try TextOperation.decodeBase64.apply(to: "not base64!"))
        XCTAssertThrowsError(try TextOperation.prettyJSON.apply(to: "{no}"))
        XCTAssertThrowsError(try TextOperation.decodeURL.apply(to: "%GG"))
    }
    func testJSONFragmentsAndStableDeduplication() throws {
        XCTAssertEqual(try TextOperation.compactJSON.apply(to: "{\"b\": 2, \"a\": 1}"), "{\"a\":1,\"b\":2}")
        XCTAssertEqual(try TextOperation.prettyJSON.apply(to: "42"), "42")
        XCTAssertEqual(try TextOperation.unique.apply(to: "b\na\nb\nc"), "b\na\nc")
    }
}

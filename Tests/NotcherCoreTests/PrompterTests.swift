import XCTest
@testable import NotcherCore

/// The teleprompter once ended in a state where play did nothing and reset could not be reached.
final class PrompterTests: XCTestCase {
    private func prompter(content: CGFloat = 1000, viewport: CGFloat = 200) -> PrompterScroll {
        var scroll = PrompterScroll(); scroll.measure(contentHeight: content, viewport: viewport); return scroll
    }
    func testScrollsToTheEndAndStopsThere() {
        var scroll = prompter()
        scroll.toggle()
        XCTAssertTrue(scroll.playing)
        scroll.advance(by: 300)
        XCTAssertEqual(scroll.offset, 300)
        scroll.advance(by: 5000)
        XCTAssertEqual(scroll.offset, scroll.end)
        XCTAssertFalse(scroll.playing, "Reaching the end stops the scroll")
        XCTAssertLessThan(scroll.end, 1000, "The last lines stay on screen")
    }
    func testPlayAtTheEndStartsAgainFromTheTop() {
        var scroll = prompter()
        scroll.toggle(); scroll.advance(by: 5000)
        scroll.toggle()
        XCTAssertTrue(scroll.playing)
        XCTAssertEqual(scroll.offset, 0)
        scroll.advance(by: 10)
        XCTAssertTrue(scroll.playing, "It must keep playing, not fall back to paused")
    }
    func testResetAlwaysReturnsToTheTop() {
        var scroll = prompter()
        scroll.toggle(); scroll.advance(by: 400); scroll.toggle()
        scroll.reset()
        XCTAssertEqual([scroll.offset, scroll.playing ? 1 : 0], [0, 0])
        scroll.toggle(); scroll.advance(by: 5000); scroll.reset(); scroll.reset()
        XCTAssertEqual(scroll.offset, 0)
        scroll.toggle()
        XCTAssertTrue(scroll.playing)
    }
    func testPausedTextDoesNotMove() {
        var scroll = prompter()
        scroll.advance(by: 100)
        XCTAssertEqual(scroll.offset, 0)
        scroll.toggle(); scroll.advance(by: 100); scroll.pause(); scroll.advance(by: 100)
        XCTAssertEqual(scroll.offset, 100)
    }
    func testTextThatFitsOrIsMissingCannotBePlayed() {
        for scroll in [prompter(content: 60), prompter(content: 0), PrompterScroll()] {
            var copy = scroll
            XCTAssertFalse(copy.canPlay)
            copy.toggle()
            XCTAssertFalse(copy.playing)
        }
    }
    func testShorterTextBringsTheWindowBackInsideIt() {
        var scroll = prompter()
        scroll.toggle(); scroll.advance(by: 800)
        scroll.measure(contentHeight: 300, viewport: 200)
        XCTAssertEqual(scroll.offset, scroll.end)
        scroll.measure(contentHeight: 0, viewport: 200)
        XCTAssertEqual(scroll.offset, 0)
        XCTAssertFalse(scroll.playing)
        scroll.measure(contentHeight: .nan, viewport: .infinity)
        XCTAssertFalse(scroll.canPlay)
    }
    func testAnyPressSequenceLeavesAUsablePrompter() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var scroll = prompter(content: CGFloat(Int.random(in: 0...2000, using: &generator)), viewport: CGFloat(Int.random(in: 0...400, using: &generator)))
            for _ in 0..<40 {
                switch Int.random(in: 0...4, using: &generator) {
                case 0: scroll.toggle()
                case 1: scroll.reset()
                case 2: scroll.pause()
                case 3: scroll.advance(by: CGFloat(Int.random(in: -50...900, using: &generator)))
                default: scroll.measure(contentHeight: CGFloat(Int.random(in: 0...2000, using: &generator)), viewport: CGFloat(Int.random(in: 0...400, using: &generator)))
                }
                XCTAssertTrue(scroll.offset >= 0 && scroll.offset <= scroll.end)
                XCTAssertFalse(scroll.playing && !scroll.canPlay)
            }
            // Whatever happened before, reset then play works whenever there is something to scroll.
            scroll.reset(); scroll.toggle()
            XCTAssertEqual(scroll.playing, scroll.canPlay)
        }
    }
}

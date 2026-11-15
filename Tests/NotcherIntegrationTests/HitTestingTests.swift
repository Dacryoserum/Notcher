import XCTest
import SwiftUI
import AppKit
@testable import Notcher

/// Content hidden by a clip still takes clicks. A scrolled teleprompter text once lay unseen over the whole
/// panel that way and left every button under it dead. These tests click for real, in a window.
final class HitTestingTests: XCTestCase {
    private final class Counter: ObservableObject { var presses = 0 }

    /// A button, and under it a small window onto a very tall text pushed up over the button.
    private struct Stage: View {
        let counter: Counter
        let textTakesClicks: Bool
        let contained: Bool
        var body: some View {
            VStack(spacing: 0) {
                Button { counter.presses += 1 } label: { Color.blue.frame(width: 200, height: 40).contentShape(Rectangle()) }.buttonStyle(.plain)
                area.frame(width: 200, height: 60)
            }.frame(width: 200, height: 100)
        }
        @ViewBuilder private var area: some View {
            let text = GeometryReader { _ in
                Text(String(repeating: "Lorem ipsum dolor sit amet\n", count: 40)).font(.system(size: 28)).frame(width: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).offset(y: -300)
            }.clipped().allowsHitTesting(textTakesClicks)
            if contained { text.contentShape(Rectangle()) } else { text }
        }
    }
    @MainActor private func pressesAfterClickingTheButton(textTakesClicks: Bool, contained: Bool) -> Int {
        let counter = Counter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Stage(counter: counter, textTakesClicks: textTakesClicks, contained: contained))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        // The button is the top 40 points of the window; window coordinates start at the bottom.
        let point = NSPoint(x: 60, y: 80)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.close()
        return counter.presses
    }
    @MainActor func testHiddenTextCoversTheButtonAboveIt() {
        // The fault itself, kept as a test: if this ever starts passing clicks through, the two below prove nothing.
        XCTAssertEqual(pressesAfterClickingTheButton(textTakesClicks: true, contained: false), 0)
    }
    @MainActor func testTextThatTakesNoClicksLeavesTheButtonAlone() {
        XCTAssertEqual(pressesAfterClickingTheButton(textTakesClicks: false, contained: false), 1)
    }
    @MainActor func testAnAreaWithItsOwnShapeKeepsItsContentInside() {
        XCTAssertEqual(pressesAfterClickingTheButton(textTakesClicks: true, contained: true), 1)
    }
}

import XCTest
@testable import NotcherCore

final class PanelTests: XCTestCase {
    func testEveryClosedStateStaysInsideNotchHeightAndExtendsSymmetrically() {
        for height: CGFloat in [26, 32, 38] {
            for media in [false, true] {
                for focus in [false, true] {
                    for activity in [false, true] {
                        for idleInfo in [false, true] {
                            let size = CompactPanel.size(notchWidth: 190, notchHeight: height, media: media, focus: focus, activity: activity, idleInfo: idleInfo)
                            let frame = PanelGeometry.frame(size: size, topCenter: CGPoint(x: 900, y: 1000))
                            XCTAssertEqual(frame.minY, 1000 - height)
                            XCTAssertEqual(frame.maxY, 1000)
                            XCTAssertGreaterThan(size.width, 190)
                            XCTAssertEqual(900 - 95 - frame.minX, frame.maxX - (900 + 95))
                        }
                    }
                }
            }
        }
    }
    func testDiscreetClosedNotchOnlyHidesIdleInformation() {
        let idle = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: false, idleInfo: true)
        let discreet = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: false, idleInfo: false)
        XCTAssertLessThan(discreet.width, idle.width)
        for idleInfo in [false, true] {
            XCTAssertEqual(CompactPanel.size(notchWidth: 190, notchHeight: 32, media: true, focus: false, activity: false, idleInfo: idleInfo).width, 374)
            XCTAssertEqual(CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: true, idleInfo: idleInfo).width, 442)
        }
    }
    func testPanelHangsFromTopCentreOnAnOffsetDisplay() {
        let anchor = CGPoint(x: -900, y: 1800)
        for size in [CGSize(width: 298, height: 40), CGSize(width: 690, height: 436)] {
            let rect = PanelGeometry.frame(size: size, topCenter: anchor)
            XCTAssertEqual(rect.maxY, 1800, accuracy: 0.0001)
            XCTAssertEqual(rect.midX, -900, accuracy: 0.0001)
            XCTAssertEqual(rect.size, size)
        }
    }
    func testTransitionWindowHoldsBothShapesAndStaysCentred() {
        let closed = CGSize(width: 333, height: 32), open = CGSize(width: 690, height: 436)
        for (from, to) in [(closed, open), (open, closed)] {
            let window = PanelGeometry.envelope(from, to, margin: 24)
            XCTAssertGreaterThanOrEqual(window.width, 690 + 48)
            XCTAssertGreaterThanOrEqual(window.height, 436 + 24)
            XCTAssertEqual(window.width.truncatingRemainder(dividingBy: 2), 0)
        }
        // Without a margin the envelope of a shape with itself is that shape, rounded to an even width.
        XCTAssertEqual(PanelGeometry.envelope(closed, closed), CGSize(width: 334, height: 32))
        let broken = PanelGeometry.envelope(CGSize(width: CGFloat.nan, height: -4), CGSize(width: 10, height: CGFloat.infinity))
        XCTAssertEqual(broken, CGSize(width: 10, height: 1))
    }
    func testEveryMotionStyleFoldsBackWithoutVisibleOscillation() {
        for style in MotionStyle.allCases {
            XCTAssertGreaterThan(style.opening.response, 0.15)
            XCTAssertLessThan(style.opening.response, 0.6)
            XCTAssertGreaterThanOrEqual(style.closing.damping, 0.8)
            XCTAssertLessThanOrEqual(style.closing.response, style.opening.response)
        }
        XCTAssertEqual(MotionStyle(rawValue: "unknown"), nil)
        XCTAssertEqual(CloseDelay.allCases.map(\.seconds), CloseDelay.allCases.map(\.seconds).sorted())
    }
    func testHoveredNotchSwellsWithoutMovingItsTopEdge() {
        let rest = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: false)
        let hovered = CompactPanel.size(notchWidth: 190, notchHeight: 32, media: false, focus: false, activity: false, hovered: true)
        XCTAssertGreaterThan(hovered.width, rest.width)
        XCTAssertGreaterThan(hovered.height, rest.height)
        XCTAssertLessThan(hovered.height - rest.height, 8)
        XCTAssertEqual(PanelGeometry.frame(size: hovered, topCenter: CGPoint(x: 0, y: 900)).maxY, 900)
    }
    func testPausedPlayerOnlyRestsAfterItsDelay() {
        XCTAssertFalse(MediaRest.isResting(pausedFor: 299, limitMinutes: 5))
        XCTAssertTrue(MediaRest.isResting(pausedFor: 300, limitMinutes: 5))
        XCTAssertFalse(MediaRest.isResting(pausedFor: 1_000_000, limitMinutes: 0))
        XCTAssertFalse(MediaRest.isResting(pausedFor: .nan, limitMinutes: 5))
        XCTAssertEqual(MediaRest.title(minutes: 0), "Jamais")
        XCTAssertEqual(MediaRest.title(minutes: 60), "1 h")
        XCTAssertEqual(OpenMode.allCases.count, 3)
        XCTAssertNil(OpenMode(rawValue: "removed"))
    }
    func testTabInteractionDoesNotSuppressAutoCollapse() {
        // Becoming the key window after clicking a tab is deliberately not a reason to stay open.
        XCTAssertTrue(PanelDismissal.shouldClose(pointerInside: false, pinned: false, dragging: false, dialogOpen: false, editingText: false))
        XCTAssertFalse(PanelDismissal.shouldClose(pointerInside: false, pinned: true, dragging: false, dialogOpen: false, editingText: false))
        XCTAssertFalse(PanelDismissal.shouldClose(pointerInside: false, pinned: false, dragging: false, dialogOpen: true, editingText: false))
        XCTAssertFalse(PanelDismissal.shouldClose(pointerInside: false, pinned: false, dragging: false, dialogOpen: false, editingText: true))
        XCTAssertFalse(PanelDismissal.shouldClose(pointerInside: true, pinned: false, dragging: false, dialogOpen: false, editingText: false))
    }
    func testCustomColorsAreNormalizedAndInvalidSettingsCanFallBack() {
        let value = AccentColor(hex: " #87baff ")
        XCTAssertEqual(value?.hex, "87BAFF")
        XCTAssertEqual(value?.blue, 1)
        XCTAssertNil(AccentColor(hex: "#abcdef00"))
        XCTAssertNil(AccentColor(hex: "nothing"))
        XCTAssertNil(DashboardLayout(rawValue: "removed-layout"))
        XCTAssertGreaterThan(PanelSize.comfortable.width, PanelSize.compact.width)
    }
}

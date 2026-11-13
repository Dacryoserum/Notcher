import XCTest
@testable import NotcherCore

final class HomeLayoutTests: XCTestCase {
    private func assertDrawable(_ layout: HomeLayout, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(layout.items.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(layout.widgets).count, layout.widgets.count, file: file, line: line)
        var taken = Set<Int>()
        for item in layout.items {
            XCTAssertGreaterThanOrEqual(item.w, item.widget.minimum.w, file: file, line: line)
            XCTAssertGreaterThanOrEqual(item.h, item.widget.minimum.h, file: file, line: line)
            XCTAssertTrue(item.x >= 0 && item.y >= 0 && item.x + item.w <= HomeLayout.columns && item.y + item.h <= HomeLayout.rows, file: file, line: line)
            for y in item.y..<(item.y + item.h) { for x in item.x..<(item.x + item.w) {
                XCTAssertTrue(taken.insert(y * HomeLayout.columns + x).inserted, "Two widgets share a cell", file: file, line: line)
            } }
        }
    }
    func testStandardLayoutFillsTheGrid() {
        let layout = HomeLayout.standard
        XCTAssertEqual(layout.widgets, [.media, .focus, .volume, .agenda])
        XCTAssertEqual(layout.items.reduce(0) { $0 + $1.w * $1.h }, HomeLayout.columns * HomeLayout.rows)
        XCTAssertFalse(HomeLayout.standard.contains(.note))
        assertDrawable(layout)
    }
    func testResizingIsRefusedOnlyWhenThePlaceIsTaken() {
        var layout = HomeLayout.standard
        // Growing into the neighbour is refused and changes nothing.
        XCTAssertFalse(layout.setFrame(.volume, x: 0, y: 3, w: 6, h: 1))
        XCTAssertEqual(layout, .standard)
        // Shrinking is always possible, down to a single cell for a small widget…
        XCTAssertTrue(layout.setFrame(.volume, x: 0, y: 3, w: 1, h: 1))
        XCTAssertEqual(layout.item(.volume), HomeItem(.volume, x: 0, y: 3, w: 1, h: 1))
        // …which frees room for the neighbour to grow into.
        XCTAssertTrue(layout.setFrame(.agenda, x: 1, y: 3, w: 7, h: 1))
        // A widget never goes below its minimum, nor outside the grid.
        XCTAssertTrue(layout.setFrame(.agenda, x: 7, y: 3, w: 0, h: 0))
        XCTAssertEqual(layout.item(.agenda), HomeItem(.agenda, x: 6, y: 3, w: 2, h: 1))
        XCTAssertTrue(layout.setFrame(.volume, x: -5, y: 99, w: 2, h: 1))
        XCTAssertEqual(layout.item(.volume), HomeItem(.volume, x: 0, y: 3, w: 2, h: 1))
        XCTAssertFalse(layout.setFrame(.clock, x: 0, y: 0, w: 1, h: 1))
        assertDrawable(layout)
    }
    func testMovingOntoAnotherWidgetTradesPlaces() {
        var layout = HomeLayout.standard
        XCTAssertTrue(layout.move(.focus, toX: 1, y: 1))
        XCTAssertEqual(layout.item(.focus), HomeItem(.focus, x: 0, y: 0, w: 5, h: 3))
        XCTAssertEqual(layout.item(.media), HomeItem(.media, x: 5, y: 0, w: 3, h: 3))
        // Free cells are simply taken.
        XCTAssertTrue(layout.setFrame(.volume, x: 0, y: 3, w: 2, h: 1))
        XCTAssertTrue(layout.move(.volume, toX: 3, y: 3))
        XCTAssertEqual(layout.item(.volume), HomeItem(.volume, x: 3, y: 3, w: 2, h: 1))
        // A trade that would squeeze a widget below its minimum is refused.
        XCTAssertTrue(layout.setFrame(.volume, x: 4, y: 3, w: 1, h: 1))
        let before = layout
        XCTAssertFalse(layout.move(.agenda, toX: 4, y: 3))
        XCTAssertEqual(layout, before)
        XCTAssertFalse(layout.move(.clock, toX: 0, y: 0))
        assertDrawable(layout)
    }
    func testAddingFindsFreeRoomShrinksWhenNeededAndStopsWhenFull() {
        var layout = HomeLayout.standard
        XCTAssertFalse(layout.add(.clock), "The standard overview has no free cell")
        XCTAssertTrue(layout.setFrame(.volume, x: 0, y: 3, w: 2, h: 1))
        XCTAssertTrue(layout.add(.clock))
        XCTAssertEqual(layout.item(.clock), HomeItem(.clock, x: 2, y: 3, w: 2, h: 1))
        XCTAssertTrue(layout.add(.awake))
        XCTAssertEqual(layout.item(.awake), HomeItem(.awake, x: 4, y: 3, w: 1, h: 1))
        XCTAssertFalse(layout.add(.battery))
        XCTAssertFalse(layout.add(.clock))
        assertDrawable(layout)
        var empty = HomeLayout(items: [HomeItem(.clock, x: 0, y: 0, w: 1, h: 1)])
        XCTAssertTrue(empty.add(.media))
        XCTAssertEqual(empty.item(.media)?.w, HomeWidget.media.preferred.w)
    }
    func testRemovingKeepsAtLeastOneWidget() {
        var layout = HomeLayout.standard
        XCTAssertTrue(layout.remove(.media)); XCTAssertTrue(layout.remove(.focus)); XCTAssertTrue(layout.remove(.volume))
        XCTAssertFalse(layout.remove(.agenda))
        XCTAssertFalse(layout.remove(.clock))
        XCTAssertEqual(layout.widgets, [.agenda])
        XCTAssertEqual(layout.available.count, HomeWidget.allCases.count - 1)
    }
    func testFramesTileTheAreaWithoutOverflow() {
        let size = CGSize(width: 626, height: 320)
        var union = CGRect.null
        for item in HomeLayout.standard.items {
            let frame = HomeLayout.frame(of: item, in: size, spacing: 12)
            XCTAssertTrue(frame.minX >= 0 && frame.minY >= 0)
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.001); XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.001)
            union = union.union(frame)
        }
        XCTAssertEqual(union.width, 626, accuracy: 0.001); XCTAssertEqual(union.height, 320, accuracy: 0.001)
        let cell = HomeLayout.cellSize(in: size, spacing: 12)
        XCTAssertEqual(HomeLayout.frame(of: HomeItem(.clock, x: 1, y: 1, w: 1, h: 1), in: size, spacing: 12).size, cell)
        XCTAssertGreaterThan(HomeLayout.cellSize(in: .zero, spacing: 12).width, 0)
    }
    func testDamagedOrOldSettingsAlwaysRestoreADrawableLayout() {
        XCTAssertEqual(HomeLayout.restore(nil), .standard)
        XCTAssertEqual(HomeLayout.restore(Data("nonsense".utf8)), .standard)
        XCTAssertEqual(HomeLayout.restore(Data(#"{"items":[]}"#.utf8)), .standard)
        let messy = Data(#"{"items":[{"widget":"media","x":0,"y":0,"w":40,"h":2},{"widget":"media","x":0,"y":3,"w":1,"h":1},{"widget":"clock","x":2,"y":1,"w":2,"h":1},{"widget":"agenda","x":7,"y":3,"w":1,"h":1}]}"#.utf8)
        let restored = HomeLayout.restore(messy)
        assertDrawable(restored)
        XCTAssertEqual(restored.widgets, [.media, .agenda])
        XCTAssertEqual(restored.item(.agenda), HomeItem(.agenda, x: 6, y: 3, w: 2, h: 1))
        // A widget from a future version makes the value unreadable rather than half applied.
        XCTAssertEqual(HomeLayout.restore(Data(#"{"items":[{"widget":"weather","x":0,"y":0,"w":1,"h":1}]}"#.utf8)), .standard)
        var custom = HomeLayout.standard; custom.setFrame(.volume, x: 0, y: 3, w: 1, h: 1); custom.add(.awake)
        XCTAssertEqual(HomeLayout.restore(custom.encoded), custom)
    }
    func testRowLayoutOfEarlierBuildsIsConverted() {
        let old = Data(#"{"rows":[[{"widget":"agenda","wide":true},{"widget":"volume","wide":false}],[{"widget":"focus","wide":true},{"widget":"media","wide":false}]],"balance":"top"}"#.utf8)
        let layout = HomeLayout.restore(old)
        assertDrawable(layout)
        XCTAssertEqual(layout.widgets, [.agenda, .volume, .focus, .media])
        XCTAssertEqual(layout.item(.agenda), HomeItem(.agenda, x: 0, y: 0, w: 5, h: 3))
        XCTAssertEqual(layout.item(.media), HomeItem(.media, x: 5, y: 3, w: 3, h: 1))
        let single = HomeLayout.restore(Data(#"{"rows":[[{"widget":"note","wide":true},{"widget":"clock","wide":false},{"widget":"battery","wide":false}],[]],"balance":"even"}"#.utf8))
        assertDrawable(single)
        XCTAssertEqual(single.widgets, [.note, .clock, .battery])
        XCTAssertTrue(single.items.allSatisfy { $0.h == HomeLayout.rows })
    }
}

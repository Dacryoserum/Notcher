import XCTest
@testable import NotcherCore

final class HomeLayoutTests: XCTestCase {
    private func assertDrawable(_ layout: HomeLayout, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.rows.count, 2, file: file, line: line)
        XCTAssertFalse(layout.rows[0].isEmpty, file: file, line: line)
        XCTAssertEqual(Set(layout.widgets).count, layout.widgets.count, file: file, line: line)
        for row in layout.rows {
            XCTAssertLessThanOrEqual(row.count, HomeLayout.maxTiles, file: file, line: line)
            XCTAssertLessThanOrEqual(row.reduce(0) { $0 + $1.weight }, HomeLayout.maxWeight, file: file, line: line)
        }
    }
    func testStandardLayoutMatchesTheOriginalOverview() {
        let layout = HomeLayout.standard
        XCTAssertEqual(layout.widgets, [.media, .focus, .volume, .agenda])
        XCTAssertEqual(layout.heights(total: 320, spacing: 12), [200, 108])
        XCTAssertEqual(layout.available.count, HomeWidget.allCases.count - 4)
        assertDrawable(layout)
    }
    func testAddingFillsTheEmptiestRowAndStopsWhenFull() {
        var layout = HomeLayout.standard
        XCTAssertTrue(layout.add(.note)); XCTAssertTrue(layout.add(.clock))
        XCTAssertEqual(layout.rows.map(\.count), [3, 3])
        XCTAssertFalse(layout.add(.battery))
        XCTAssertFalse(layout.add(.note))
        XCTAssertFalse(layout.contains(.battery))
        assertDrawable(layout)
    }
    func testRemovingKeepsAtLeastOneWidgetAndNeverLeavesTheTopRowEmpty() {
        var layout = HomeLayout.standard
        XCTAssertTrue(layout.remove(.media)); XCTAssertTrue(layout.remove(.focus))
        XCTAssertEqual(layout.rows[0].map(\.widget), [.volume, .agenda])
        XCTAssertTrue(layout.rows[1].isEmpty)
        XCTAssertEqual(layout.heights(total: 320, spacing: 12), [320, 0])
        XCTAssertTrue(layout.remove(.volume))
        XCTAssertFalse(layout.remove(.agenda))
        XCTAssertFalse(layout.remove(.clock))
        assertDrawable(layout)
    }
    func testMovingWithinAndBetweenRowsTakesTheTargetsPlace() {
        var layout = HomeLayout.standard
        XCTAssertTrue(layout.place(.focus, row: 0, index: 0))
        XCTAssertEqual(layout.rows[0].map(\.widget), [.focus, .media])
        XCTAssertTrue(layout.place(.agenda, row: 0, index: 1))
        XCTAssertEqual(layout.rows[0].map(\.widget), [.focus, .agenda, .media])
        XCTAssertEqual(layout.rows[1].map(\.widget), [.volume])
        // The top row is full: a tile dropped on one of its tiles trades places with it.
        XCTAssertTrue(layout.place(.volume, row: 0, index: 0))
        XCTAssertEqual(layout.rows[0].map(\.widget), [.volume, .agenda, .media])
        XCTAssertEqual(layout.rows[1].map(\.widget), [.focus])
        // A new widget cannot be pushed into a full row, and out-of-range targets are refused.
        XCTAssertFalse(layout.place(.clock, row: 0, index: 1))
        XCTAssertFalse(layout.place(.clock, row: 5, index: 0))
        XCTAssertTrue(layout.place(.clock, row: 1, index: 99))
        XCTAssertEqual(layout.rows[1].map(\.widget), [.focus, .clock])
        assertDrawable(layout)
    }
    func testWideningNarrowsNeighboursInsteadOfOverflowing() {
        var layout = HomeLayout(rows: [[HomeTile(.media, wide: true), HomeTile(.focus), HomeTile(.clock)], []])
        layout.setWide(.clock, true)
        XCTAssertTrue(layout.isWide(.clock)); XCTAssertFalse(layout.isWide(.media))
        layout.setWide(.focus, true)
        XCTAssertTrue(layout.isWide(.focus))
        assertDrawable(layout)
        let widths = layout.widths(row: 0, total: 626, spacing: 12)
        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThanOrEqual(widths.min() ?? 0, 150)
        XCTAssertLessThanOrEqual(widths.reduce(0, +) + 24, 626)
    }
    func testRowBalanceAndSizesNeverProduceNegativeOrOverflowingSpace() {
        for balance in RowBalance.allCases {
            var layout = HomeLayout.standard; layout.balance = balance
            for total: CGFloat in [0, 50, 320, 380] {
                let heights = layout.heights(total: total, spacing: 12)
                XCTAssertTrue(heights.allSatisfy { $0 >= 0 })
                XCTAssertLessThanOrEqual(heights.reduce(0, +) + 12, max(total, 12))
            }
        }
        var layout = HomeLayout.standard; layout.balance = .bottom
        XCTAssertEqual(layout.heights(total: 320, spacing: 12), [108, 200])
        layout.balance = .even
        XCTAssertEqual(layout.heights(total: 320, spacing: 12), [154, 154])
        XCTAssertEqual(layout.widths(row: 7, total: 600, spacing: 12), [])
    }
    func testDamagedOrOldSettingsAlwaysRestoreADrawableLayout() throws {
        XCTAssertEqual(HomeLayout.restore(nil), .standard)
        XCTAssertEqual(HomeLayout.restore(Data("nonsense".utf8)), .standard)
        let duplicated = Data(#"{"rows":[[{"widget":"media","wide":true},{"widget":"media","wide":true},{"widget":"clock","wide":true},{"widget":"note","wide":true},{"widget":"files","wide":false}],[],[{"widget":"agenda","wide":false}]]}"#.utf8)
        let restored = HomeLayout.restore(duplicated)
        assertDrawable(restored)
        XCTAssertEqual(restored.rows[0].map(\.widget), [.media, .clock, .note])
        XCTAssertEqual(HomeLayout.restore(Data(#"{"rows":[[],[]]}"#.utf8)), .standard)
        // A widget removed from a future version makes the whole value unreadable rather than half applied.
        XCTAssertEqual(HomeLayout.restore(Data(#"{"rows":[[{"widget":"weather","wide":false}],[]]}"#.utf8)), .standard)
        var custom = HomeLayout.standard; custom.add(.note); custom.balance = .even
        XCTAssertEqual(HomeLayout.restore(custom.encoded), custom)
        let migrated = try XCTUnwrap(HomeLayout.migrating(slots: ["agenda", "volume", "focus", "media"]))
        XCTAssertEqual(migrated.widgets, [.agenda, .volume, .focus, .media])
        XCTAssertTrue(migrated.isWide(.agenda)); XCTAssertFalse(migrated.isWide(.volume))
        XCTAssertNil(HomeLayout.migrating(slots: ["media", "media", "focus", "volume"]))
    }
}

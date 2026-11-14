import XCTest
@testable import NotcherCore

final class HotKeyTests: XCTestCase {
    func testStandardShortcutIsCommandShiftSpace() {
        XCTAssertEqual(HotKeyCombo.standard.keyCode, 49)
        XCTAssertEqual(HotKeyCombo.standard.symbols, ["⇧", "⌘"])
        XCTAssertTrue(HotKeyCombo.standard.isUsable)
    }
    func testModifiersFollowMenuOrder() {
        let combo = HotKeyCombo(keyCode: 40, command: true, option: true, control: true, shift: true, key: "K")
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘K")
    }
    func testPlainKeysNeedAModifierButFunctionKeysDoNot() {
        XCTAssertFalse(HotKeyCombo(keyCode: 40, key: "K").isUsable)
        XCTAssertFalse(HotKeyCombo(keyCode: 40, shift: true, key: "K").isUsable)
        XCTAssertTrue(HotKeyCombo(keyCode: 40, option: true, key: "K").isUsable)
        XCTAssertTrue(HotKeyCombo(keyCode: 96, key: "F5").isUsable)
        XCTAssertEqual(HotKeyCombo.name(forKeyCode: 96), "F5")
        XCTAssertEqual(HotKeyCombo.name(forKeyCode: 49), "Espace")
        XCTAssertNil(HotKeyCombo.name(forKeyCode: 40))
    }
    func testShortcutsThatWouldStealFromAppsOrMacOSAreReserved() {
        XCTAssertFalse(HotKeyCombo.standard.isReserved)
        XCTAssertTrue(HotKeyCombo(keyCode: 8, command: true, key: "C").isReserved)
        XCTAssertTrue(HotKeyCombo(keyCode: 45, command: true, shift: true, key: "N").isReserved)
        XCTAssertTrue(HotKeyCombo(keyCode: 123, command: true, key: "←").isReserved)
        XCTAssertTrue(HotKeyCombo(keyCode: 49, command: true, key: "Espace").isReserved, "Spotlight")
        XCTAssertTrue(HotKeyCombo(keyCode: 48, command: true, key: "⇥").isReserved, "App switcher")
        XCTAssertTrue(HotKeyCombo(keyCode: 21, command: true, shift: true, key: "4").isReserved, "Screenshot")
        XCTAssertFalse(HotKeyCombo(keyCode: 40, command: true, option: true, key: "K").isReserved)
        XCTAssertFalse(HotKeyCombo(keyCode: 40, control: true, key: "K").isReserved)
        XCTAssertFalse(HotKeyCombo(keyCode: 96, command: true, key: "F5").isReserved)
    }
    func testMenuAndCarbonEncodings() {
        XCTAssertEqual(HotKeyCombo.standard.carbonModifiers, 0x0300)
        XCTAssertEqual(HotKeyCombo(keyCode: 40, option: true, control: true, key: "K").carbonModifiers, 0x1800)
        XCTAssertEqual(HotKeyCombo.standard.keyEquivalent, " ")
        XCTAssertEqual(HotKeyCombo(keyCode: 40, option: true, key: "K").keyEquivalent, "k")
        XCTAssertEqual(HotKeyCombo(keyCode: 117, option: true, key: "⌦").keyEquivalent.unicodeScalars.first?.value, 0xF728)
        XCTAssertEqual(HotKeyCombo(keyCode: 51, option: true, key: "⌫").keyEquivalent.unicodeScalars.first?.value, 0x08)
        XCTAssertEqual(HotKeyCombo(keyCode: 115, option: true, key: "↖").keyEquivalent.unicodeScalars.first?.value, 0xF729)
        XCTAssertEqual(HotKeyCombo(keyCode: 96, key: "F5").keyEquivalent.unicodeScalars.first?.value, 0xF708)
    }
    func testStoredShortcutSurvivesAndBadDataFallsBack() {
        let combo = HotKeyCombo(keyCode: 45, control: true, key: "N")
        XCTAssertEqual(HotKeyCombo.restore(combo.encoded), combo)
        XCTAssertEqual(HotKeyCombo.restore(nil), .standard)
        XCTAssertEqual(HotKeyCombo.restore(Data("nope".utf8)), .standard)
        XCTAssertEqual(HotKeyCombo.restore(HotKeyCombo(keyCode: 40, key: "K").encoded), .standard)
    }
}

final class ShelfExpiryTests: XCTestCase {
    func testPinnedOrKeptForeverNeverExpires() {
        let added = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ShelfExpiry.date(of: ShelfItem(name: "a", addedAt: added, byteCount: 1, isPinned: true), retentionHours: 24))
        XCTAssertNil(ShelfExpiry.date(of: ShelfItem(name: "a", addedAt: added, byteCount: 1), retentionHours: 0))
        XCTAssertEqual(ShelfExpiry.date(of: ShelfItem(name: "a", addedAt: added, byteCount: 1), retentionHours: 24), added.addingTimeInterval(86_400))
    }
    func testLabelsRoundUp() {
        XCTAssertEqual(ShelfExpiry.label(remaining: -30), "1 min")
        XCTAssertEqual(ShelfExpiry.label(remaining: 61), "2 min")
        XCTAssertEqual(ShelfExpiry.label(remaining: 3600), "1 h")
        XCTAssertEqual(ShelfExpiry.label(remaining: 3601), "2 h")
        XCTAssertEqual(ShelfExpiry.label(remaining: 47 * 3600), "47 h")
        XCTAssertEqual(ShelfExpiry.label(remaining: 7 * 86_400), "7 j")
        XCTAssertTrue(ShelfExpiry.isSoon(remaining: 3599))
        XCTAssertFalse(ShelfExpiry.isSoon(remaining: 3600))
    }
}

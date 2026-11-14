import XCTest
import NotcherCore
@testable import Notcher

/// Selection and undoable removal only; no repository is opened, so nothing touches the disk.
final class ShelfSelectionTests: XCTestCase {
    @MainActor private func shelf(_ count: Int) -> (ShelfService, [ShelfItem]) {
        let service = ShelfService()
        let items = (0..<count).map { ShelfItem(name: "f\($0)", byteCount: 1, isPinned: $0 == 0) }
        service.items = items
        return (service, items)
    }
    @MainActor func testClickCommandAndShiftFollowTheFinder() {
        let (service, items) = shelf(5)
        service.click(items[1], command: false, shift: false, among: items)
        XCTAssertEqual(service.selection, [items[1].id])
        service.click(items[3], command: true, shift: false, among: items)
        XCTAssertEqual(service.selection, [items[1].id, items[3].id])
        service.click(items[3], command: true, shift: false, among: items)
        XCTAssertEqual(service.selection, [items[1].id])
        service.click(items[1], command: false, shift: false, among: items)
        service.click(items[4], command: false, shift: true, among: items)
        XCTAssertEqual(service.selection, Set(items[1...4].map(\.id)))
    }
    @MainActor func testRemovalHidesAtOnceAndUndoBringsBack() {
        let (service, items) = shelf(4)
        service.selection = [items[2].id]
        XCTAssertEqual(service.unpinned, Set(items[1...].map(\.id)))
        XCTAssertEqual(service.remove(service.unpinned), 3)
        XCTAssertEqual(service.items, [items[0]])
        XCTAssertTrue(service.selection.isEmpty)
        XCTAssertTrue(service.canUndo)
        service.undoRemoval()
        XCTAssertEqual(service.items, items)
        XCTAssertFalse(service.canUndo)
    }
    @MainActor func testRemovingTwiceDoesNotCountHiddenCopies() {
        let (service, items) = shelf(3)
        XCTAssertEqual(service.remove([items[1].id]), 1)
        XCTAssertEqual(service.remove([items[1].id]), 0)
    }
}

/// What the shelf's keys and its undo toast do, below the views: the closest to an interface test that
/// a Swift package can run.
final class ShelfKeyboardTests: XCTestCase {
    override func setUp() {
        // AppPaths is process-wide; keep anything the model might touch out of the real support folder.
        setenv("NOTCHER_DATA_DIR", FileManager.default.temporaryDirectory.appendingPathComponent("notcher-integration-support-\(getpid())").path, 1)
    }
    @MainActor private func model(_ count: Int) -> (AppModel, [ShelfItem]) {
        let model = AppModel()
        let items = (0..<count).map { ShelfItem(name: "f\($0)", byteCount: 1, isPinned: $0 == 0) }
        model.shelf.items = items
        model.tab = .files
        return (model, items)
    }
    @MainActor func testKeysOnlyActOnTheShelfTab() {
        let (model, items) = model(3)
        model.shelf.selection = [items[1].id]
        model.tab = .notes
        XCTAssertFalse(model.handleShelfKey(keyCode: 51, characters: nil, command: false))
        XCTAssertEqual(model.shelf.items.count, 3)
    }
    @MainActor func testDeleteRemovesTheSelectionAndOffersUndo() throws {
        let (model, items) = model(3)
        XCTAssertFalse(model.handleShelfKey(keyCode: 51, characters: nil, command: false), "Nothing selected: the key is left to others")
        model.shelf.selection = [items[1].id, items[2].id]
        XCTAssertTrue(model.handleShelfKey(keyCode: 51, characters: nil, command: false))
        XCTAssertEqual(model.shelf.items, [items[0]])
        XCTAssertEqual(model.toast, L("%lld fichiers retirés", 2))
        let action = try XCTUnwrap(model.toastAction)
        action.run()
        XCTAssertEqual(model.shelf.items, items)
        XCTAssertNil(model.toast)
    }
    @MainActor func testCommandZUndoesAndCommandASelectsAll() {
        let (model, items) = model(3)
        XCTAssertTrue(model.handleShelfKey(keyCode: 0, characters: "a", command: true))
        XCTAssertEqual(model.shelf.selection, Set(items.map(\.id)))
        XCTAssertFalse(model.handleShelfKey(keyCode: 6, characters: "z", command: true), "Nothing to undo")
        model.removeFromShelf(model.shelf.unpinned)
        XCTAssertTrue(model.handleShelfKey(keyCode: 6, characters: "z", command: true))
        XCTAssertEqual(model.shelf.items, items)
    }
    @MainActor func testEscapeClearsTheSelectionBeforeClosingThePanel() {
        let (model, items) = model(2)
        model.shelf.selection = [items[1].id]
        XCTAssertTrue(model.handleShelfKey(keyCode: 53, characters: nil, command: false))
        XCTAssertTrue(model.shelf.selection.isEmpty)
        XCTAssertFalse(model.handleShelfKey(keyCode: 53, characters: nil, command: false), "Nothing selected: Escape closes the panel")
    }
    @MainActor func testSelectAllAndClearOnlyTakeWhatTheSearchShows() {
        let (model, items) = model(4)
        model.shelf.query = "f2"
        XCTAssertTrue(model.handleShelfKey(keyCode: 0, characters: "a", command: true))
        XCTAssertEqual(model.shelf.selection, [items[2].id])
        XCTAssertEqual(model.shelf.unpinned, [items[2].id])
    }
    @MainActor func testEachDialogReleasesOnlyItsOwnHold() {
        let (model, _) = model(0)
        let first = model.beginDialog(), second = model.beginDialog()
        model.endDialog(first)
        XCTAssertTrue(model.dialogOpen, "A second window is still open")
        model.endDialog(first)
        XCTAssertTrue(model.dialogOpen)
        model.endDialog(second)
        XCTAssertFalse(model.dialogOpen)
    }
    @MainActor func testAMessageRaisedWhileClosedWaitsForThePanel() {
        let (model, _) = model(0)
        model.notifyWhenOpen("Bonjour")
        XCTAssertNil(model.toast)
        model.expand()
        XCTAssertEqual(model.toast, "Bonjour")
    }
}

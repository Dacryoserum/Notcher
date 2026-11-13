import AppKit
import XCTest
@testable import Notcher

final class EditorTests: XCTestCase {
    @MainActor func testCreatingASheetUsesAnImplementedAppKitInitializer() {
        let id = UUID()
        let editor = SheetTextView(id: id)
        XCTAssertEqual(editor.id, id)
        XCTAssertNotNil(editor.textContainer)
        XCTAssertNotNil(editor.layoutManager)
        XCTAssertTrue(editor.isEditable)
        XCTAssertFalse(editor.isRichText)
        editor.string = "Une fiche native"
        XCTAssertEqual(editor.string, "Une fiche native")
    }
    @MainActor func testAppKitFrameInitializerCanDelegateToTheDesignatedInitializer() {
        let editor = SheetTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertNotNil(editor.textStorage)
        XCTAssertTrue(editor.allowsUndo)
    }
    @MainActor func testEachSheetHasItsOwnTextAndUndoManager() {
        let first = SheetTextView(id: UUID()), second = SheetTextView(id: UUID())
        first.insertText("Première fiche", replacementRange: NSRange(location: 0, length: 0))
        second.insertText("Deuxième fiche", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(first.undoManager === second.undoManager)
        first.breakUndoCoalescing()
        first.undoManager?.undo()
        XCTAssertEqual(first.string, "")
        XCTAssertEqual(second.string, "Deuxième fiche")
    }
    @MainActor func testEmptySheetFillsItsViewportAndSurvivesResizing() {
        let scroll = SheetScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        let editor = SheetTextView(id: UUID())
        scroll.documentView = editor
        for size in [NSSize(width: 400, height: 220), NSSize(width: 540, height: 280), NSSize(width: 320, height: 160)] {
            scroll.setFrameSize(size)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentSize.height)
            XCTAssertEqual(editor.frame.width, scroll.contentSize.width, accuracy: 0.5)
        }
    }
}

import XCTest
import NotcherCore
@testable import Notcher

final class NotesTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("notes.json") }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-sheets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    @MainActor func testThreeSheetsKeepIndependentTextAndRestoreSelection() throws {
        let notes = NotesService(file: file)
        XCTAssertEqual(notes.notes.count, 3)
        let first = notes.notes[0].id, second = notes.notes[1].id
        notes.update(text: "Premier texte 👋", title: "A")
        notes.select(second); XCTAssertEqual(notes.selected?.text, "")
        notes.update(text: "Deuxième texte", title: "B")
        notes.select(first); XCTAssertEqual(notes.selected?.text, "Premier texte 👋")
        notes.select(second); notes.save()
        let reopened = NotesService(file: file)
        XCTAssertEqual(reopened.selectedID, second)
        XCTAssertEqual(reopened.selected?.text, "Deuxième texte")
        reopened.select(first); XCTAssertEqual(reopened.selected?.text, "Premier texte 👋")
    }
    @MainActor func testLegacyNotesMigrateWithoutLosingIDsOrContent() throws {
        let original = ScratchNote(title: "Ancienne note", text: "À conserver")
        try JSONEncoder().encode([original]).write(to: file)
        let notes = NotesService(file: file)
        XCTAssertEqual(notes.notes[0], original)
        XCTAssertEqual(notes.notes.count, 3)
        notes.save()
        let book = try ScratchBook.read(Data(contentsOf: file))
        XCTAssertEqual(book.notes[0], original)
    }
    @MainActor func testLateEditIsRoutedToItsOriginalSheet() throws {
        let notes = NotesService(file: file)
        let first = notes.notes[0].id, second = notes.notes[1].id
        notes.select(second); notes.update(text: "Courante")
        notes.update(id: first, text: "Dernière composition IME")
        XCTAssertEqual(notes.selected?.text, "Courante")
        notes.select(first); XCTAssertEqual(notes.selected?.text, "Dernière composition IME")
    }
    @MainActor func testAddingAndDeletingNeverOverwritesOtherSheets() throws {
        let notes = NotesService(file: file)
        let first = notes.selectedID!
        notes.update(text: "Garder")
        notes.add(); let created = notes.selectedID!
        XCTAssertNotEqual(created, first); XCTAssertEqual(notes.selected?.text, "")
        notes.removeSelected(); XCTAssertEqual(notes.notes.count, 3)
        notes.select(first); XCTAssertEqual(notes.selected?.text, "Garder")
        notes.select(notes.notes[1].id); notes.removeSelected()
        XCTAssertEqual(notes.notes.count, 3)
        notes.select(first); XCTAssertEqual(notes.selected?.text, "Garder")
    }
    @MainActor func testAutosaveAndFinalFlushCannotRestoreOlderText() async throws {
        let notes = NotesService(file: file)
        notes.update(text: String(repeating: "Initial ", count: 80_000))
        try await Task.sleep(for: .milliseconds(450))
        notes.update(text: "Dernière version"); notes.select(notes.notes[2].id)
        notes.save()
        let book = try ScratchBook.read(Data(contentsOf: file))
        XCTAssertEqual(book.notes[0].text, "Dernière version")
        XCTAssertEqual(book.selectedID, notes.notes[2].id)
    }
    @MainActor func testCorruptOrNewerArchiveIsPreserved() throws {
        for data in [Data("invalid".utf8), Data(#"{"version":999,"notes":[]}"#.utf8)] {
            try data.write(to: file)
            let notes = NotesService(file: file)
            XCTAssertNotNil(notes.error)
            notes.update(text: "Ne pas écraser"); notes.save()
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
}

import Foundation

public struct ScratchBook: Codable, Sendable {
    public var version = 1
    public var notes: [ScratchNote]
    public var selectedID: UUID?
    public init(notes: [ScratchNote] = [], selectedID: UUID? = nil) {
        self.notes = notes; self.selectedID = selectedID
        normalize()
    }
    public static func read(_ data: Data) throws -> ScratchBook {
        let decoder = JSONDecoder()
        // Preserve every existing note when migrating the original array format.
        if let legacy = try? decoder.decode([ScratchNote].self, from: data) { return ScratchBook(notes: legacy) }
        var book = try decoder.decode(ScratchBook.self, from: data)
        guard book.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        book.normalize(); return book
    }
    public mutating func normalize() {
        while notes.count < 3 { notes.append(ScratchNote()) }
        if !notes.contains(where: { $0.id == selectedID }) { selectedID = notes.first?.id }
    }
}

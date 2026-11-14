import XCTest
@testable import NotcherCore

final class ShelfTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func source(_ name: String = "file.txt", text: String = "original") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url); return url
    }
    private func store(capacity: Int64 = 10000) throws -> FileShelfStore { try FileShelfStore(root: directory.appendingPathComponent("shelf"), capacity: capacity) }

    func testRemovingSeveralCopiesWritesTheIndexOnce() throws {
        let repository = try store()
        let items = try (0..<3).map { try repository.add(try source("f\($0).txt")) }
        try repository.remove(Set([items[0].id, items[2].id]))
        XCTAssertEqual(repository.items.map(\.id), [items[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try repository.fileURL(for: items[0]).path))
        XCTAssertEqual(try store().items.map(\.id), [items[1].id], "The index on disk matches")
    }
    func testImportCopiesAndRemovalNeverDeletesOriginal() throws {
        let original = try source(), repository = try store()
        let item = try repository.add(original)
        let copy = try repository.fileURL(for: item)
        XCTAssertEqual(try Data(contentsOf: copy), Data("original".utf8))
        try repository.remove(item.id)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
    func testDuplicateNamesRemainIndependentAndPersist() throws {
        let original = try source(), repository = try store()
        let first = try repository.add(original), second = try repository.add(original)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(try repository.fileURL(for: first), try repository.fileURL(for: second))
        XCTAssertEqual(try store().items, repository.items)
    }
    func testRetentionProtectsPinnedCopies() throws {
        let original = try source(), repository = try store()
        let old = Date(timeIntervalSince1970: 100)
        let pinned = try repository.add(original, at: old)
        try repository.togglePin(pinned.id)
        _ = try repository.add(original, at: old)
        _ = try repository.add(original, at: Date(timeIntervalSince1970: 300))
        try repository.purge(olderThan: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(repository.items.count, 2)
        XCTAssertTrue(repository.items.contains { $0.id == pinned.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testCapacityRefusesCopyWithoutChangingIndex() throws {
        let original = try source(), repository = try store(capacity: 3)
        XCTAssertThrowsError(try repository.add(original))
        XCTAssertTrue(repository.items.isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }
    func testDirectoryCopyAndCapacity() throws {
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let repository = try store()
        let item = try repository.add(folder)
        XCTAssertEqual(item.byteCount, 6)
        XCTAssertEqual(try String(contentsOf: repository.fileURL(for: item).appendingPathComponent("a.txt"), encoding: .utf8), "abcdef")
    }
    func testUntrustedIndexRejectsPathTraversal() throws {
        let root = directory.appendingPathComponent("shelf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = ShelfItem(name: "../../file.txt", byteCount: 1)
        try JSONEncoder().encode([item]).write(to: root.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try FileShelfStore(root: root))
    }
    func testCorruptIndexIsPreserved() throws {
        let root = directory.appendingPathComponent("shelf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("index.json")
        try Data("not json".utf8).write(to: index)
        XCTAssertThrowsError(try FileShelfStore(root: root))
        XCTAssertEqual(try String(contentsOf: index, encoding: .utf8), "not json")
    }
    func testCannotImportShelfIntoItself() throws {
        let repository = try store()
        XCTAssertThrowsError(try repository.add(repository.root))
        XCTAssertThrowsError(try repository.add(directory))
        XCTAssertTrue(repository.items.isEmpty)
    }
    func testNestedSymlinkDoesNotCreateAnAliasToTheOriginal() throws {
        let original = try source()
        let folder = directory.appendingPathComponent("linked-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: original)
        let repository = try store()
        XCTAssertThrowsError(try repository.add(folder))
        XCTAssertTrue(repository.items.isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }
}

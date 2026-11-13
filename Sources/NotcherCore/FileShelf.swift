import Foundation

public struct ShelfItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var addedAt: Date
    public var byteCount: Int64
    public var isPinned: Bool
    public init(id: UUID = UUID(), name: String, addedAt: Date = Date(), byteCount: Int64, isPinned: Bool = false) {
        self.id = id; self.name = name; self.addedAt = addedAt; self.byteCount = byteCount; self.isPinned = isPinned
    }
}

public enum ShelfError: LocalizedError {
    case tooLarge, unsafePath, missingFile, symbolicLink, containsShelf
    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "Le dépôt est limité à 2 Go. Libérez de la place ou choisissez un fichier plus petit."
        case .unsafePath: return "Le nom de ce fichier n’est pas valide."
        case .missingFile: return "Ce fichier n’est plus disponible."
        case .symbolicLink: return "Ce dossier contient un lien symbolique. Ajoutez directement sa cible pour en conserver une copie indépendante."
        case .containsShelf: return "Le dépôt ne peut pas être copié à l’intérieur de lui-même."
        }
    }
}

/// Owns copies only. Original files are never moved or deleted.
/// Access is serialized by the caller (ShelfService's dedicated queue).
public final class FileShelfStore {
    public private(set) var items: [ShelfItem]
    public let root: URL
    public let capacity: Int64
    private let fm = FileManager.default
    private var index: URL { root.appendingPathComponent("index.json") }

    public init(root: URL, capacity: Int64 = 2_000_000_000) throws {
        self.root = root; self.capacity = capacity
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("index.json")
        if fm.fileExists(atPath: url.path) {
            items = try JSONDecoder().decode([ShelfItem].self, from: Data(contentsOf: url))
        } else { items = [] }
        // A corrupt index must never allow access outside our directory.
        for item in items { try Self.validate(name: item.name) }
    }

    public func fileURL(for item: ShelfItem) throws -> URL {
        try Self.validate(name: item.name)
        return root.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent(item.name)
    }

    @discardableResult public func add(_ original: URL, at date: Date = Date()) throws -> ShelfItem {
        let source = original.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: source.path) else { throw ShelfError.missingFile }
        let ownedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        guard ownedRoot != sourcePath, !ownedRoot.hasPrefix(sourcePath + "/") else { throw ShelfError.containsShelf }
        try Self.validate(name: source.lastPathComponent)
        let available = capacity - items.reduce(0) { $0 + $1.byteCount }
        let size = try Self.size(of: source, maximum: max(0, available))
        guard size <= available else { throw ShelfError.tooLarge }
        var item = ShelfItem(name: source.lastPathComponent, addedAt: date, byteCount: size)
        let directory = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try fm.copyItem(at: source, to: try fileURL(for: item))
            // The source may have grown during the copy (for example, a download).
            item.byteCount = try Self.size(of: fileURL(for: item), maximum: available)
            let next = [item] + items
            try save(next)
            items = next
            return item
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    public func remove(_ id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { return }
        let next = items.filter { $0.id != id }
        try save(next)
        items = next
        let ownedDirectory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if fm.fileExists(atPath: ownedDirectory.path) { try fm.removeItem(at: ownedDirectory) }
    }
    public func togglePin(_ id: UUID) throws {
        var next = items
        guard let position = next.firstIndex(where: { $0.id == id }) else { return }
        next[position].isPinned.toggle()
        try save(next); items = next
    }
    public func purge(olderThan cutoff: Date) throws {
        for item in items where !item.isPinned && item.addedAt < cutoff { try remove(item.id) }
    }
    private func save(_ value: [ShelfItem]) throws {
        try JSONEncoder().encode(value).write(to: index, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }
    private static func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw ShelfError.unsafePath }
    }
    private static func size(of url: URL, maximum: Int64) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isDirectory != true {
            let count = Int64(values.fileSize ?? 0)
            guard count <= maximum else { throw ShelfError.tooLarge }
            return count
        }
        var total: Int64 = 0
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw ShelfError.missingFile }
        for case let child as URL in enumerator {
            let info = try child.resourceValues(forKeys: keys)
            guard info.isSymbolicLink != true else { throw ShelfError.symbolicLink }
            if info.isDirectory != true { total += Int64(info.fileSize ?? 0) }
            if total > maximum { throw ShelfError.tooLarge }
        }
        if let enumerationError { throw enumerationError }
        return total
    }
}

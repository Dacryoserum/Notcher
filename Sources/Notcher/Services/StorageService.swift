import AppKit
import Combine
import NotcherCore
import UniformTypeIdentifiers

actor ShelfRepository {
    private let store: FileShelfStore
    init(root: URL) throws { store = try FileShelfStore(root: root) }
    func items() -> [ShelfItem] { store.items }
    func add(_ url: URL) throws -> [ShelfItem] { try store.add(url); return store.items }
    func remove(_ ids: Set<UUID>) throws -> [ShelfItem] { try store.remove(ids); return store.items }
    func pin(_ id: UUID) throws -> [ShelfItem] { try store.togglePin(id); return store.items }
    func purge(hours: Int) throws -> [ShelfItem] {
        if hours > 0 { try store.purge(olderThan: Date().addingTimeInterval(-Double(hours) * 3600)) }
        return store.items
    }
}

@MainActor final class ShelfService: ObservableObject {
    /// What the repository holds, including copies whose removal can still be undone.
    @Published private var stored: [ShelfItem] = []
    /// Removed from view, deleted from disk once the undo window has passed.
    @Published private var pending: Set<UUID> = []
    /// Past the undo window, being deleted from disk: never shown again.
    @Published private var deleting: Set<UUID> = []
    @Published var selection: Set<UUID> = []
    /// The search typed above the cards; every action on "all" means all that is shown.
    @Published var query = ""
    var visible: [ShelfItem] {
        let all = items
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    /// Anchor of a ⇧-click range.
    var selectionAnchor: UUID?
    private var pendingTask: Task<Void, Never>?
    /// How long a removal can be undone.
    static let undoWindow: TimeInterval = 5
    var items: [ShelfItem] {
        get { pending.isEmpty && deleting.isEmpty ? stored : stored.filter { !pending.contains($0.id) && !deleting.contains($0.id) } }
        set { stored = newValue; selection.formIntersection(Set(newValue.map(\.id))) }
    }
    @Published var importing = false
    @Published var error: String?
    let root = AppPaths.support.appendingPathComponent("Shelf", isDirectory: true)
    private var repository: ShelfRepository?
    var onAdded: ((Int) -> Void)?
    func start(retentionHours: Int) {
        do { repository = try ShelfRepository(root: root) }
        catch { self.error = L("Impossible d’ouvrir le dépôt : %@", error.localizedDescription); return }
        purge(hours: retentionHours)
    }
    func purge(hours: Int) {
        Task {
            do { items = try await repository?.purge(hours: hours) ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }
    func url(for item: ShelfItem) -> URL { root.appendingPathComponent(item.id.uuidString).appendingPathComponent(item.name) }
    func add(_ urls: [URL]) {
        guard let repository else { return }
        Task {
            importing = true; defer { importing = false }
            var count = 0
            for url in urls where url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { items = try await repository.add(url); count += 1 }
                catch { self.error = error.localizedDescription }
            }
            if count > 0 { onAdded?(count) }
        }
    }
    func addText(_ value: String) {
        Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: directory) }
                let timestamp = Date().formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: "-")
                let url = directory.appendingPathComponent(L("Texte %@", timestamp)).appendingPathExtension("txt")
                try Data(value.utf8).write(to: url)
                if let repository { items = try await repository.add(url); onAdded?(1) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func remove(_ item: ShelfItem) { remove([item.id]) }
    /// Hides the copies at once; they are deleted when the undo window closes, or by the next removal.
    @discardableResult func remove(_ ids: Set<UUID>) -> Int {
        let removed = ids.subtracting(pending).intersection(Set(stored.map(\.id)))
        guard !removed.isEmpty else { return 0 }
        commitRemovals()
        pending = removed
        selection.subtract(removed)
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.undoWindow)) } catch { return }
            self?.commitRemovals()
        }
        return removed.count
    }
    /// The copies not kept with a pin.
    var unpinned: Set<UUID> { Set(visible.filter { !$0.isPinned }.map(\.id)) }
    var canUndo: Bool { !pending.isEmpty }
    func undoRemoval() {
        pendingTask?.cancel(); pendingTask = nil
        pending = []
    }
    func commitRemovals() {
        pendingTask?.cancel(); pendingTask = nil
        let ids = pending
        pending = []
        guard !ids.isEmpty, let repository else { return }
        deleting.formUnion(ids)
        let previous = deletion
        deletion = Task {
            await previous?.value
            do { stored = try await repository.remove(ids) } catch { self.error = error.localizedDescription }
            deleting.subtract(ids)
        }
    }
    /// Deletions still owed to the disk, chained so they finish in order.
    private var deletion: Task<Void, Never>?
    /// Whether quitting now would leave removed copies on disk.
    var hasUnfinishedRemovals: Bool { !pending.isEmpty || !deleting.isEmpty }
    /// Deletes everything removed so far, including copies still in their undo window. Used before quitting.
    func finishRemovals() async {
        commitRemovals()
        await deletion?.value
    }
    func selected() -> [ShelfItem] { items.filter { selection.contains($0.id) } }
    /// Finder rules: a click selects one card, ⌘ adds or removes it, ⇧ extends from the last one clicked.
    func click(_ item: ShelfItem, command: Bool, shift: Bool, among visible: [ShelfItem]) {
        if shift, let anchor = selectionAnchor, let from = visible.firstIndex(where: { $0.id == anchor }), let to = visible.firstIndex(where: { $0.id == item.id }) {
            let range = visible[min(from, to)...max(from, to)].map(\.id)
            selection = command ? selection.union(range) : Set(range)
            return
        }
        if command {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else { selection = [item.id] }
        selectionAnchor = item.id
    }
    func pin(_ item: ShelfItem) { Task { do { items = try await repository?.pin(item.id) ?? stored } catch { self.error = error.localizedDescription } } }
    func chooseFiles(onFinish: @escaping () -> Void = {}) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.prompt = L("Ajouter au dépôt")
        panel.begin { [weak self] result in Task { @MainActor in if result == .OK { self?.add(panel.urls) }; onFinish() } }
    }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, _ in
                    let url: URL?
                    if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let item = value as? URL { url = item }
                    else { url = nil }
                    if let url { Task { @MainActor in self?.add([url]) } }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                    if let value = value as? String { Task { @MainActor in self?.addText(value) } }
                }
            }
        }
        return accepted
    }
}

/// Writes are serialized so an older autosave can never replace a newer one.
private final class NoteFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.notcher.notes", qos: .utility)
    private let file: URL
    init(file: URL) { self.file = file }
    func write(_ book: ScratchBook, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do { try persist(book); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    func flush(_ book: ScratchBook) throws { try queue.sync { try persist(book) } }
    private func persist(_ book: ScratchBook) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(book).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@MainActor final class NotesService: ObservableObject {
    @Published private(set) var notes: [ScratchNote] = []
    @Published private(set) var selectedID: UUID?
    @Published var error: String?
    private var subscriptions = Set<AnyCancellable>()
    private let writer: NoteFileWriter
    private var canSave = true
    private var writeRevision = 0
    init(file: URL = AppPaths.support.appendingPathComponent("notes.json")) {
        writer = NoteFileWriter(file: file)
        var book = ScratchBook()
        do {
            if FileManager.default.fileExists(atPath: file.path) { book = try ScratchBook.read(Data(contentsOf: file)) }
        } catch { self.error = "Les fiches n’ont pas pu être ouvertes. Le fichier original est conservé."; canSave = false }
        notes = book.notes; selectedID = book.selectedID
        Publishers.Merge($notes.dropFirst().map { _ in () }, $selectedID.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.autosave() }.store(in: &subscriptions)
    }
    var selected: ScratchNote? { notes.first { $0.id == selectedID } }
    private var book: ScratchBook { ScratchBook(notes: notes, selectedID: selectedID) }
    func select(_ id: UUID) {
        guard selectedID != id, notes.contains(where: { $0.id == id }) else { return }
        selectedID = id; error = canSave ? nil : error
    }
    func update(id: UUID? = nil, text: String? = nil, title: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == (id ?? selectedID) }) else { return }
        guard (text != nil && notes[index].text != text) || (title != nil && notes[index].title != title) else { return }
        var note = notes[index]
        if let text { note.text = text }
        if let title { note.title = title }
        note.updatedAt = Date(); notes[index] = note
    }
    func add() { let note = ScratchNote(); notes.append(note); selectedID = note.id }
    func removeSelected() {
        guard let index = notes.firstIndex(where: { $0.id == selectedID }) else { return }
        notes.remove(at: index)
        while notes.count < 3 { notes.append(ScratchNote()) }
        selectedID = notes[min(index, notes.count - 1)].id
    }
    func transform(_ operation: TextOperation) {
        guard let selected else { return }
        do { update(text: try operation.apply(to: selected.text)) }
        catch { self.error = error.localizedDescription }
    }
    private func autosave() {
        guard canSave else { return }
        writeRevision += 1
        let revision = writeRevision
        writer.write(book) { [weak self] message in
            Task { @MainActor in
                guard let self, self.writeRevision == revision else { return }
                self.error = message.map { L("Échec de la sauvegarde : %@", $0) }
            }
        }
    }
    /// Flush at application termination (or explicit test checkpoint), never on every keystroke.
    func save() {
        guard canSave else { return }
        writeRevision += 1
        do { try writer.flush(book); error = nil }
        catch { self.error = L("Échec de la sauvegarde des fiches : %@", error.localizedDescription) }
    }
    /// Text of a sheet as the HTML body Apple Notes expects, and the title it should carry.
    nonisolated static func appleNote(title: String, text: String) -> (name: String, body: String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let custom = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = lines
        var name = custom
        if custom.isEmpty || custom == "Sans titre" {
            // An untitled sheet is named after its first line, which then leaves the body.
            guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            name = String(lines[first].trimmingCharacters(in: .whitespaces).prefix(120))
            content = Array(lines[(first + 1)...])
        }
        guard !name.isEmpty else { return nil }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = content.map { $0.isEmpty ? "<div><br></div>" : "<div>" + escape($0) + "</div>" }.joined()
        return (name, body)
    }
    @Published private(set) var sending = false
    /// Creates a note in Apple Notes from the selected sheet. `completion` receives nil on success.
    func sendToNotes(completion: @escaping (String?) -> Void) {
        guard !sending else { return }
        guard let note = selected, let content = Self.appleNote(title: note.title, text: note.text) else { completion(L("Cette fiche est vide.")); return }
        sending = true
        Task {
            defer { sending = false }
            do {
                // The text travels as arguments, never inside the script: nothing in a sheet can be run as code.
                let script = ["-e", "on run argv", "-e", "tell application \"Notes\" to make new note with properties {name:(item 1 of argv), body:(item 2 of argv)}", "-e", "end run", "--", content.name, content.body]
                let result = try await Command.run("/usr/bin/osascript", script, timeout: 60)
                completion(result.status == 0 ? nil : L("Notes est inaccessible. Autorise Notcher dans Réglages Système → Confidentialité → Automatisation."))
            } catch { completion(error.localizedDescription) }
        }
    }
    func export(onFinish: @escaping () -> Void = {}) {
        guard let note = selected else { onFinish(); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = note.title + ".txt"; panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] result in
            defer { onFinish() }
            guard result == .OK, let url = panel.url else { return }
            do { try Data(note.text.utf8).write(to: url, options: .atomic) }
            catch { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
}

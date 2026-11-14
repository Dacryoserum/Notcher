import SwiftUI
import QuickLookUI
import QuickLookThumbnailing
import NotcherCore

struct ShelfView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfService
    @ObservedObject private var preferences: Preferences
    init(model: AppModel, shelf: ShelfService) {
        self.model = model; self.shelf = shelf; preferences = model.preferences
    }
    var body: some View {
        // Filtered once per render, then handed to every card.
        let visible = shelf.visible
        VStack(alignment: .leading, spacing: 12) {
            header
            if shelf.items.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(accent.opacity(model.dragging ? 0.08 : 0.02))
                    RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    EmptyState(symbol: "tray.and.arrow.down", title: "Déposer des fichiers")
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Retrouver un fichier…", text: $shelf.query).textFieldStyle(.plain)
                    Text(ByteCountFormatter.string(fromByteCount: shelf.items.reduce(0) { $0 + $1.byteCount }, countStyle: .file)).foregroundStyle(Theme.muted)
                }.font(.system(size: 10)).padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    // Remaining times move by the minute without anything else changing.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                            ForEach(visible) { item in fileCard(item, among: visible, now: context.date) }
                        }
                    }
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { shelf.selection = [] })
                }.scrollIndicators(.hidden)
            }
            ErrorLine(message: shelf.error)
        }
        .animation(.snappy(duration: 0.2), value: shelf.items)
        .animation(.easeOut(duration: 0.12), value: shelf.selection)
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text("Fichiers").font(.system(size: 17, weight: .semibold))
            if !shelf.selection.isEmpty {
                Text(L(shelf.selection.count > 1 ? "%lld sélectionnés" : "%lld sélectionné", shelf.selection.count))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(accent.opacity(0.10), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Spacer()
            if shelf.importing { ProgressView().controlSize(.small) }
            if !shelf.selection.isEmpty {
                IconButton(symbol: "eye", help: "Aperçu · Espace") { model.toggleShelfPreview() }
                IconButton(symbol: "airplayaudio", help: "Envoyer par AirDrop") { airDrop(shelf.selected()) }
                IconButton(symbol: "trash", help: "Retirer la sélection · ⌫") { model.removeFromShelf(shelf.selection) }
            } else if !shelf.unpinned.isEmpty {
                IconButton(symbol: "trash", help: "Vider le dépôt (les fichiers épinglés restent)") { model.removeFromShelf(shelf.unpinned) }
            }
            CapsuleButton(title: "Ajouter", symbol: "plus", primary: true) { let token = model.beginDialog(); shelf.chooseFiles { model.endDialog(token) } }
        }
    }
    private func fileCard(_ item: ShelfItem, among visible: [ShelfItem], now: Date) -> some View {
        let url = shelf.url(for: item)
        let selected = shelf.selection.contains(item.id)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                FileThumbnail(url: url, side: 40)
                Text(item.name).font(.system(size: 10, weight: .medium)).lineLimit(2).frame(height: 26, alignment: .top)
                meta(item, now: now)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                ShelfDragSource(selected: selected,
                                urls: { [shelf] in
                                    // Dragging a selected card carries the whole selection, like the Finder.
                                    let chosen = shelf.selection.contains(item.id) ? shelf.selected() : [item]
                                    return chosen.map(shelf.url(for:))
                                },
                                click: { [shelf, visible] flags in shelf.click(item, command: flags.contains(.command), shift: flags.contains(.shift), among: visible) },
                                open: { NSWorkspace.shared.open(url) },
                                help: L("Espace pour l’aperçu · Glisser pour exporter · Double-clic pour ouvrir"))
            )
            HStack(spacing: 4) {
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(accent) }
                menu(item, url: url)
            }.padding(.top, 10).padding(.trailing, 8)
        }
        .background(selected ? accent.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? accent.opacity(0.75) : Theme.border, lineWidth: selected ? 1.5 : 1))
        .accessibilityElement(children: .contain).accessibilityLabel(item.name).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// Size, and for a copy that will leave, how long it has left.
    @ViewBuilder private func meta(_ item: ShelfItem, now: Date) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
        if let end = ShelfExpiry.date(of: item, retentionHours: preferences.retentionHours) {
            let remaining = end.timeIntervalSince(now)
            let soon = ShelfExpiry.isSoon(remaining: remaining)
            HStack(spacing: 4) {
                Text(size)
                Text(verbatim: "·")
                Image(systemName: "clock").font(.system(size: 7))
                Text(ShelfExpiry.label(remaining: remaining))
            }.font(.system(size: 9)).foregroundStyle(soon ? Theme.orange : Theme.muted).lineLimit(1)
                .help(L("Retiré automatiquement %@. Épingle-le pour le garder.", end.formatted(.relative(presentation: .named))))
        } else {
            Text(size).font(.system(size: 9)).foregroundStyle(Theme.muted)
        }
    }
    private func menu(_ item: ShelfItem, url: URL) -> some View {
        Menu {
            Button("Aperçu", systemImage: "eye") { model.preview([url]) }
            Button("Ouvrir", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            Button("Afficher dans le Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop", systemImage: "airplayaudio") { airDrop([item]) }
            Button("Copier le fichier", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]); model.notify("Fichier copié") }
            Button(L(item.isPinned ? "Désépingler" : "Conserver"), systemImage: "pin") { shelf.pin(item) }
            Divider()
            Button("Retirer la copie", systemImage: "trash", role: .destructive) { model.removeFromShelf([item.id]) }
        } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 20, height: 20).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
    }
    private func airDrop(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items.map { shelf.url(for: $0) as NSURL })
    }
}

// MARK: - Thumbnails

/// The file's real picture (a photo, the first page of a PDF…), or its Finder icon while there is none.
struct FileThumbnail: View {
    @Environment(\.displayScale) private var scale
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .transition(.opacity)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, side: side, scale: scale) }
    }
}

/// Shelf copies never change once made, so a thumbnail is generated once per file and size.
@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    /// Requests under way: a file shown twice (card and widget) is generated once.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Last failure per file: tried again after a while, since Quick Look can fail for a moment.
    private var failedAt: [String: Date] = [:]
    static let retryDelay: TimeInterval = 60
    init() { cache.countLimit = 300 }
    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(Int(side * scale))"
        if let image = cache.object(forKey: key as NSString) { return image }
        if let failure = failedAt[key], Date().timeIntervalSince(failure) < Self.retryDelay { return nil }
        if let running = inFlight[key] { return await running.value }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        let task = Task<NSImage?, Never> { try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString); failedAt[key] = nil } else { failedAt[key] = Date() }
        return image
    }
}

// MARK: - Mouse and drag

/// Clicks and drags of a shelf card, handled by AppKit: SwiftUI can only drag one file at a time.
struct ShelfDragSource: NSViewRepresentable {
    let selected: Bool
    let urls: () -> [URL]
    let click: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    let help: String
    func makeNSView(context: Context) -> ShelfDragView { ShelfDragView() }
    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.selected = selected; view.urls = urls; view.click = click; view.open = open; view.toolTip = help
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    var selected = false
    var urls: () -> [URL] = { [] }
    var click: (NSEvent.ModifierFlags) -> Void = { _ in }
    var open: () -> Void = {}
    private var down: NSEvent?
    /// A plain click on a card already selected keeps the selection until the button is released,
    /// so several cards can be dragged together.
    private var selectOnRelease = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { down = nil; selectOnRelease = false; open(); return }
        down = event
        let flags = event.modifierFlags.intersection([.command, .shift])
        if selected && flags.isEmpty { selectOnRelease = true } else { selectOnRelease = false; click(flags) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        self.down = nil; selectOnRelease = false
        let files = urls()
        guard !files.isEmpty else { return }
        let point = convert(start, from: nil)
        let items = files.prefix(24).enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(min(index, 4)) * 5
            item.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48), contents: icon)
            return item
        }
        // Past the first 24 files the pictures add nothing; every file is still carried.
        let extra = files.dropFirst(24).map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: nil)
            return item
        }
        let session = beginDraggingSession(with: items + extra, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }
    override func mouseUp(with event: NSEvent) {
        if selectOnRelease { click([]) }
        selectOnRelease = false; down = nil
    }
    /// Only other apps receive the files: dropped back on the notch, they would be copied a second time.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

// MARK: - Quick Look

@MainActor final class FilePreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var urls: [URL] = []
    private var onClose: (() -> Void)?
    private var observation: NSKeyValueObservation?
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true }
    func owns(_ window: NSWindow?) -> Bool { window != nil && QLPreviewPanel.sharedPreviewPanelExists() && window === QLPreviewPanel.shared() }
    /// Several files: the arrow keys move between them, as in the Finder.
    func show(_ urls: [URL], onClose: @escaping () -> Void = {}) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { onClose(); return }
        finish()
        self.urls = urls; self.onClose = onClose
        panel.dataSource = self; panel.reloadData(); panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        // Quick Look closes itself (Escape, its own button): the shelf has to know.
        observation = panel.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in self?.finish() }
        }
    }
    func close() {
        if isVisible { QLPreviewPanel.shared()?.orderOut(nil) }
        finish()
    }
    private func finish() {
        observation?.invalidate(); observation = nil
        let callback = onClose; onClose = nil
        callback?()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls.indices.contains(index) ? urls[index] as NSURL : nil }
}

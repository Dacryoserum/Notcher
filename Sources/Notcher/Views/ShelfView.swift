import SwiftUI
import QuickLookUI
import NotcherCore

struct ShelfView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfService
    @State private var query = ""
    private var visible: [ShelfItem] { shelf.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fichiers").font(.system(size: 17, weight: .semibold))
                Spacer()
                if shelf.importing { ProgressView().controlSize(.small) }
                CapsuleButton(title: "Ajouter", symbol: "plus", primary: true) { model.dialogOpen = true; shelf.chooseFiles { model.dialogOpen = false } }
            }
            if shelf.items.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(accent.opacity(model.dragging ? 0.08 : 0.02))
                    RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    EmptyState(symbol: "tray.and.arrow.down", title: "Déposer des fichiers")
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Retrouver un fichier…", text: $query).textFieldStyle(.plain)
                    Text(ByteCountFormatter.string(fromByteCount: shelf.items.reduce(0) { $0 + $1.byteCount }, countStyle: .file)).foregroundStyle(Theme.muted)
                }.font(.system(size: 10)).padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                        ForEach(visible) { item in fileCard(item) }
                    }
                }.scrollIndicators(.hidden)
            }
            ErrorLine(message: shelf.error)
        }
    }
    private func fileCard(_ item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: shelf.url(for: item).path)).resizable().frame(width: 30, height: 30)
                Spacer()
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(accent) }
                Menu {
                    Button("Aperçu", systemImage: "eye") { FilePreview.shared.show(shelf.url(for: item)) }
                    Button("Ouvrir", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(shelf.url(for: item)) }
                    Button("Afficher dans le Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([shelf.url(for: item)]) }
                    Button("AirDrop", systemImage: "airplayaudio") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [shelf.url(for: item)]) }
                    Button("Copier le fichier", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([shelf.url(for: item) as NSURL]); model.notify("Fichier copié") }
                    Button(item.isPinned ? "Désépingler" : "Conserver", systemImage: "pin") { shelf.pin(item) }
                    Divider()
                    Button("Retirer la copie", systemImage: "trash", role: .destructive) { shelf.remove(item) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)) }.menuStyle(.borderlessButton).frame(width: 17)
            }
            Text(item.name).font(.system(size: 10, weight: .medium)).lineLimit(2).frame(height: 26, alignment: .top)
            Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).font(.system(size: 9)).foregroundStyle(Theme.muted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border))
            .onTapGesture(count: 2) { NSWorkspace.shared.open(shelf.url(for: item)) }
            .onDrag { NSItemProvider(contentsOf: shelf.url(for: item)) ?? NSItemProvider() }
            .help("Glisser pour exporter · Double-clic pour ouvrir")
    }
}

@MainActor final class FilePreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

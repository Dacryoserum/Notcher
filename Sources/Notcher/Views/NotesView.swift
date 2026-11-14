import SwiftUI
import NotcherCore

struct NotesView: View {
    @Environment(\.notcherAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var notes: NotesService
    @State private var confirmDelete = false
    @State private var confirmToken: UUID?
    @State private var undoText: [UUID: String] = [:]
    /// 0 at rest; ±1 while the newly chosen sheet is still arriving from below or above.
    @State private var arrival: CGFloat = 0
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                let id = notes.selectedID
                TextField("Sans titre", text: Binding(get: { notes.selected.map { $0.title == "Sans titre" ? "" : $0.title } ?? "" }, set: { notes.update(id: id, title: $0) }))
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .medium))
                Spacer()
                IconButton(symbol: "square.and.arrow.up.on.square", help: "Envoyer vers Notes", tint: notes.sending ? accent : .secondary) { model.sendSelectedNoteToNotes() }.disabled(notes.sending)
                IconButton(symbol: "square.and.arrow.up", help: "Exporter la fiche") { let token = model.beginDialog(); notes.export { model.endDialog(token) } }
                IconButton(symbol: "trash", help: "Supprimer la fiche") { confirmDelete = true }
            }
            HStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14).fill(Theme.surface)
                    if notes.selected?.text.isEmpty != false {
                        Text("Texte…").font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.22))
                            .padding(.horizontal, 17).padding(.vertical, 12).allowsHitTesting(false)
                    }
                    ScratchEditor(notes: notes, accent: accent).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .opacity(1 - abs(arrival) * 0.75).offset(y: arrival * 10).scaleEffect(1 - abs(arrival) * 0.015)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(abs(arrival) * 0.5)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
                sheets
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(TextOperation.allCases) { operation in
                        Button(L(operation.rawValue)) {
                            if let selected = notes.selected { undoText[selected.id] = selected.text }
                            notes.transform(operation)
                        }
                    }
                } label: { Label("Transformer", systemImage: "wand.and.stars").font(.system(size: 10)) }.menuStyle(.borderlessButton).fixedSize()
                if let id = notes.selectedID, let previous = undoText[id] {
                    IconButton(symbol: "arrow.uturn.backward", help: "Annuler la transformation") { notes.update(text: previous); undoText[id] = nil }
                }
                Spacer()
                Text(L("%lld caractères", notes.selected?.text.count ?? 0)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
                CapsuleButton(title: "Copier", symbol: "doc.on.doc") { copyToClipboard(notes.selected?.text ?? ""); model.notify("Texte copié") }
            }
            ErrorLine(message: notes.error)
        }
        .onChange(of: confirmDelete) { _, value in
            if value { confirmToken = model.beginDialog() } else if let token = confirmToken { model.endDialog(token); confirmToken = nil }
        }
        .onChange(of: notes.selectedID) { old, new in
            guard !reduceMotion, let new, old != new else { return }
            let from = notes.notes.firstIndex { $0.id == old } ?? 0, to = notes.notes.firstIndex { $0.id == new } ?? 0
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { arrival = to >= from ? 1 : -1 }
            DispatchQueue.main.async { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { arrival = 0 } }
        }
        .confirmationDialog("Supprimer cette fiche ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer la fiche", role: .destructive) { if let id = notes.selectedID { undoText[id] = nil }; notes.removeSelected() }
            Button("Annuler", role: .cancel) {}
        }
    }
    private var sheets: some View {
        VStack(spacing: 8) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(Array(notes.notes.enumerated()), id: \.element.id) { index, note in
                            let active = note.id == notes.selectedID
                            let shapes = ["circle", "square", "diamond", "triangle", "pentagon", "hexagon"]
                            Button { if !active { Haptics.play(.alignment) }; notes.select(note.id) } label: {
                                Image(systemName: shapes[index % shapes.count] + (active || !note.text.isEmpty ? ".fill" : ""))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(active ? accent : Color.white.opacity(note.text.isEmpty ? 0.28 : 0.6))
                                    .frame(width: 38, height: 38)
                                    .background(active ? accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 11))
                                    .overlay(alignment: .leading) { if active { Capsule().fill(accent).frame(width: 2, height: 12) } }
                                    .contentShape(Rectangle())
                            }.buttonStyle(PressStyle(scale: 0.9)).id(note.id)
                                .help(L("Fiche %lld · ", index + 1) + (note.title == "Sans titre" ? String(note.text.prefix(60)) : note.title))
                                .accessibilityLabel(L("Fiche %lld, %@", index + 1, L(note.title)))
                                .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                }.scrollIndicators(.hidden)
                    .onChange(of: notes.selectedID) { _, id in
                        if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { reader.scrollTo(id) } }
                    }
            }
            IconButton(symbol: "plus", help: "Nouvelle fiche", tint: accent, size: 38, action: notes.add)
        }.frame(width: 38)
    }
}

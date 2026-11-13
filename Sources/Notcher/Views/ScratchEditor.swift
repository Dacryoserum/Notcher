import SwiftUI
import NotcherCore

/// Each sheet keeps its own native text view and undo manager. Delayed edits carry their sheet ID.
struct ScratchEditor: NSViewRepresentable {
    @ObservedObject var notes: NotesService
    var accent: Color
    func makeCoordinator() -> Coordinator { Coordinator(notes: notes) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SheetScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let note = notes.selected else { return }
        let coordinator = context.coordinator
        coordinator.notes = notes
        let existingIDs = Set(notes.notes.map(\.id))
        coordinator.editors = coordinator.editors.filter { existingIDs.contains($0.key) }
        let text = coordinator.editors[note.id] ?? SheetTextView(id: note.id)
        coordinator.editors[note.id] = text
        text.delegate = coordinator
        text.selectedTextAttributes = [.backgroundColor: NSColor(accent).withAlphaComponent(0.3)]
        text.insertionPointColor = NSColor(accent)
        let switching = (scroll.documentView as? SheetTextView)?.id != note.id
        let wasEditing = scroll.window?.firstResponder === scroll.documentView
        if switching {
            if let previous = scroll.documentView as? SheetTextView {
                previous.unmarkText()
                previous.breakUndoCoalescing()
                previous.savedScroll = scroll.contentView.bounds.origin
            }
            text.frame.size.width = scroll.contentSize.width
            scroll.documentView = text
        }
        if text.string != note.text {
            let selection = text.selectedRange()
            text.string = note.text
            text.sheetUndo.removeAllActions()
            let count = (note.text as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
        }
        if switching {
            if let container = text.textContainer {
                text.layoutManager?.ensureLayout(forBoundingRect: CGRect(origin: text.savedScroll, size: scroll.contentSize), in: container)
            }
            let bounds = CGRect(origin: text.savedScroll, size: scroll.contentView.bounds.size)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            if wasEditing { scroll.window?.makeFirstResponder(text) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var notes: NotesService
        var editors: [UUID: SheetTextView] = [:]
        init(notes: NotesService) { self.notes = notes }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? SheetTextView else { return }
            notes.update(id: text.id, text: text.string)
        }
    }
}

final class SheetScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? SheetTextView else { return }
        // Empty sheets must cover the viewport, so clicking anywhere can start editing.
        let viewport = contentSize
        text.minSize = NSSize(width: 0, height: viewport.height)
        let size = NSSize(width: viewport.width, height: max(viewport.height, text.frame.height))
        if text.frame.size != size { text.setFrameSize(size) }
    }
}

final class SheetTextView: NSTextView {
    private(set) var id = UUID()
    private var retainedStorage: NSTextStorage?
    let sheetUndo = UndoManager()
    var savedScroll = CGPoint.zero
    override var undoManager: UndoManager? { sheetUndo }
    convenience init(id: UUID) {
        self.init(frame: .zero, textContainer: nil)
        self.id = id
    }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // Passing nil directly to the designated initializer creates no text system.
        // Own the TextKit 1 network explicitly, without the dynamic initializer used by init(frame:).
        let resolved: NSTextContainer
        if let container {
            resolved = container
            retainedStorage = container.layoutManager?.textStorage
        } else {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            resolved = NSTextContainer(size: NSSize(width: max(1, frameRect.width), height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(resolved)
            retainedStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolved)
        configure()
    }
    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, textContainer: nil)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        retainedStorage = textStorage
        configure()
    }
    private func configure() {
        isRichText = false; allowsUndo = true; isEditable = true; isSelectable = true
        drawsBackground = false; textColor = .white
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textContainerInset = NSSize(width: 12, height: 12)
        isVerticallyResizable = true; isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero; maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        layoutManager?.allowsNonContiguousLayout = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        setAccessibilityLabel(L("Texte de la fiche"))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The accessory app has no visible Edit menu; keep the native editing shortcuts available.
        guard window?.firstResponder === self, event.modifierFlags.intersection([.command, .control, .option]) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": if event.modifierFlags.contains(.shift) { sheetUndo.redo() } else { sheetUndo.undo() }
        case "c": copy(nil)
        case "v": pasteAsPlainText(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

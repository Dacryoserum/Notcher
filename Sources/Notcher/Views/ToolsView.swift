import SwiftUI
import NotcherCore
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

enum ToolTab: String, CaseIterable, Identifiable {
    case focus = "Pomodoro", calendar = "Agenda", mirror = "Miroir", clipboard = "Presse-papiers", shortcuts = "Raccourcis", system = "Système", prompter = "Prompteur", convert = "Convertir"
    var id: String { rawValue }
}

struct ToolsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(ToolTab.allCases) { item in
                        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { model.toolTab = item } } label: {
                            Text(L(item.rawValue)).font(.system(size: 10, weight: .medium)).padding(.horizontal, 12).frame(height: 34)
                                .foregroundStyle(model.toolTab == item ? .white : .secondary)
                                .background(model.toolTab == item ? Theme.raised : .clear, in: Capsule())
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden).frame(height: 34)
            Group {
                switch model.toolTab {
                case .focus: FocusView(focus: model.focus)
                case .calendar: CalendarView(calendar: model.calendar)
                case .mirror: MirrorView(camera: model.camera)
                case .clipboard: ClipboardView(clipboard: model.clipboard, preferences: model.preferences)
                case .shortcuts: ShortcutsView(shortcuts: model.shortcuts)
                case .system: SystemView(system: model.system, bluetooth: model.bluetooth)
                case .prompter: PrompterView(notes: model.notes)
                case .convert: ConverterView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onChange(of: model.toolTab) { _, value in if value != .mirror { model.camera.stop() } }
            .onDisappear { model.camera.stop(); model.bluetooth.cancel() }
    }
}

struct FocusView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var focus: FocusService
    @State private var task = ""
    @State private var minutes = 25
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 12) {
                FocusMini(focus: focus)
                HStack(spacing: 6) {
                    ForEach([5, 15, 25, 50], id: \.self) { value in
                        Button { focus.reset(minutes: value) } label: {
                            Text("\(value) min").font(.system(size: 10)).foregroundStyle(accent).frame(maxWidth: .infinity).frame(height: 30).background(Theme.surface, in: Capsule()).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Stepper("\(minutes) min", value: $minutes, in: 1...180).font(.system(size: 10))
                    Button("Appliquer") { focus.reset(minutes: minutes) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(accent)
                }
            }.frame(width: 230)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Ajouter une tâche…", text: $task).textFieldStyle(.plain).font(.system(size: 11)).onSubmit(add)
                        IconButton(symbol: "plus", help: "Ajouter la tâche", action: add)
                    }
                    Divider().overlay(Theme.border)
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(focus.tasks) { item in
                                HStack(spacing: 10) {
                                    Button { focus.toggleTask(item.id) } label: { Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? accent : Theme.muted).frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Terminer la tâche")
                                    Text(item.title).font(.system(size: 11)).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary).lineLimit(2)
                                    Spacer()
                                    IconButton(symbol: "xmark", help: "Retirer la tâche", size: 28) { focus.removeTask(item.id) }
                                }
                            }
                        }
                    }
                    ErrorLine(message: focus.error)
                }
            }
        }
    }
    private func add() { focus.addTask(task); task = "" }
}

struct MirrorView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var camera: CameraService
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Theme.surface)
            if camera.active {
                CameraPreview(session: camera.session).clipShape(RoundedRectangle(cornerRadius: 18))
                VStack { Spacer(); CapsuleButton(title: "Éteindre la caméra", symbol: "video.slash", action: camera.stop).padding(15) }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.rectangle").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(accent)
                    CapsuleButton(title: "Activer le miroir", symbol: "video", primary: true, action: camera.start)
                    ErrorLine(message: camera.error)
                }.padding(20)
            }
        }
    }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill
        if let connection = view.preview.connection, connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true }
        return view
    }
    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}
final class PreviewSurface: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.addSublayer(preview) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}

struct ClipboardView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var preferences: Preferences
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Eyebrow(text: "Presse-papiers")
                Spacer()
                Toggle("Activer", isOn: $preferences.clipboardEnabled).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                IconButton(symbol: "trash", help: "Vider l’historique", action: clipboard.clear)
            }
            if clipboard.items.isEmpty {
                EmptyState(symbol: "doc.on.clipboard")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(clipboard.items) { item in
                            Button { clipboard.copy(item) } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.text).font(.system(size: 11, design: .monospaced)).lineLimit(3).multilineTextAlignment(.leading)
                                        Text(item.source + " · " + item.date.formatted(.dateTime.hour().minute())).font(.system(size: 9)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer(); Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(accent)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Copier ce texte")
                        }
                    }
                }
            }
        }
    }
}

struct ShortcutsView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var shortcuts: ShortcutsService
    var body: some View {
        VStack(spacing: 12) {
            HStack { Eyebrow(text: "Raccourcis"); Spacer(); IconButton(symbol: "arrow.clockwise", help: "Actualiser les raccourcis") { Task { await shortcuts.refresh() } } }
            if shortcuts.names.isEmpty { EmptyState(symbol: "square.stack.3d.up", title: "Aucun raccourci") }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 10)], spacing: 10) {
                        ForEach(shortcuts.names, id: \.self) { name in
                            Button { shortcuts.run(name) } label: {
                                HStack { Image(systemName: shortcuts.running == name ? "hourglass" : "play.square.fill").foregroundStyle(accent); Text(name).lineLimit(2); Spacer() }
                                    .font(.system(size: 11)).padding(14).frame(maxWidth: .infinity, minHeight: 54).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(shortcuts.running != nil)
                        }
                    }
                }
            }
            ErrorLine(message: shortcuts.error)
        }.task { await shortcuts.refresh() }
    }
}

struct SystemView: View {
    @Environment(\.notcherPanelActive) private var panelActive
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var system: SystemService
    @ObservedObject var bluetooth: BluetoothService
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                AudioCard(system: system).frame(height: 126)
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Luminosité", systemImage: "sun.max").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(system.canSetBrightness ? "\(Int(system.brightness * 100)) %" : "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                        }
                        Slider(value: Binding(get: { system.brightness }, set: system.changeBrightness), in: 0...1).controlSize(.small).disabled(!system.canSetBrightness)
                        ErrorLine(message: system.displayError)
                    }.frame(maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                Card(padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "cup.and.saucer.fill").font(.system(size: 16)).foregroundStyle(system.awake ? accent : .secondary)
                            .frame(width: 36, height: 36).background(system.awake ? accent.opacity(0.12) : Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Éveil").font(.system(size: 12, weight: .medium))
                            if system.awakeUntil != nil { AwakeCountdown(system: system).foregroundStyle(accent) }
                            else { Text(L(system.awake ? "Activé" : "Désactivé")).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        AwakeSteps(system: system)
                        Toggle("Garder le Mac éveillé", isOn: Binding(get: { system.awake }, set: { _ in system.toggleAwake() })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Eyebrow(text: "Bluetooth"); Spacer()
                            if bluetooth.loading { ProgressView().controlSize(.mini) }
                            IconButton(symbol: "arrow.clockwise", help: "Actualiser le Bluetooth", size: 26, action: bluetooth.refresh).disabled(bluetooth.loading)
                        }
                        if !bluetooth.loading, bluetooth.connected.isEmpty, bluetooth.error == nil { Text("Aucun appareil").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(bluetooth.connected, id: \.self) { name in
                                    HStack(spacing: 8) {
                                        Circle().fill(accent).frame(width: 5, height: 5)
                                        Text(name).font(.system(size: 11)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 5)
                                }
                            }
                        }.scrollIndicators(.hidden)
                        ErrorLine(message: bluetooth.error)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onAppear { if panelActive { bluetooth.refresh(); system.refreshBrightness() } }
            .onChange(of: panelActive) { _, active in if active { bluetooth.refresh(); system.refreshBrightness() } else { bluetooth.cancel() } }
            .onDisappear { bluetooth.cancel() }
    }
}

struct PrompterView: View {
    @Environment(\.notcherPanelActive) private var panelActive
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var notes: NotesService
    @State private var playing = false
    @State private var offset: CGFloat = 0
    @State private var speed: Double = 22
    @State private var mirrored = false
    @State private var textHeight: CGFloat = 0
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Eyebrow(text: "Prompteur")
                Spacer()
                Toggle("Miroir", isOn: $mirrored).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                IconButton(symbol: "arrow.counterclockwise", help: "Revenir au début") { offset = 0; playing = false }
                IconButton(symbol: playing ? "pause.fill" : "play.fill", help: "Démarrer ou arrêter le prompteur", tint: accent) { playing.toggle() }
            }
            GeometryReader { geo in
                Text(notes.selected?.text ?? "")
                    .font(.system(size: 28, weight: .medium)).lineSpacing(12).frame(width: geo.size.width - 48, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { size in Color.clear.onAppear { textHeight = size.size.height }.onChange(of: size.size.height) { _, height in textHeight = height } })
                    .padding(24).offset(y: -offset).scaleEffect(x: mirrored ? -1 : 1, y: 1)
            }.clipped().background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            HStack { Text("Vitesse"); Slider(value: $speed, in: 8...70).frame(width: 150); Spacer(); Text("\(Int(speed)) px/s") }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.onChange(of: panelActive) { _, active in if !active { playing = false } }
        // Runs only while scrolling: a permanent 30 Hz timer kept firing with the prompter stopped and the notch closed.
        .task(id: playing && panelActive) {
            guard playing && panelActive else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                offset += speed / 30
                if offset >= textHeight + 24 { playing = false }
            }
        }
    }
}

struct ConverterView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @State private var source: URL?
    @State private var format = "PNG"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Card {
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.document").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                if let source { Text(source.lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(1) }
                HStack(spacing: 12) {
                    CapsuleButton(title: "Choisir une image", symbol: "photo") { choose() }
                    Picker("Format", selection: $format) { ForEach(["PNG", "JPEG", "WEBP", "TIFF", "PDF"], id: \.self) { Text(verbatim: $0) } }.labelsHidden().frame(width: 90)
                    CapsuleButton(title: busy ? "Conversion…" : "Convertir", primary: true) { convert() }.disabled(source == nil || busy)
                }
                ErrorLine(message: error)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func choose() {
        model.dialogOpen = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.begin { response in model.dialogOpen = false; if response == .OK { source = panel.url; error = nil } }
    }
    private func convert() {
        guard let source else { return }
        busy = true
        let selectedFormat = format
        Task {
            defer { busy = false }
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: source)
                    guard data.count < 100_000_000, let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide * bitmap.pixelsHigh < 100_000_000 else { throw CommandError.failed("Cette image est trop grande ou son format n’est pas lisible.") }
                    let output: Data
                    if selectedFormat == "PDF" {
                        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)); image.addRepresentation(bitmap)
                        guard let page = PDFPage(image: image) else { throw CommandError.unavailable }
                        let document = PDFDocument(); document.insert(page, at: 0)
                        guard let pdf = document.dataRepresentation() else { throw CommandError.unavailable }; output = pdf
                    } else if selectedFormat == "WEBP" {
                        // macOS reads WebP but cannot write it: the app carries its own lossless encoder.
                        guard bitmap.pixelsWide * bitmap.pixelsHigh <= 40_000_000, let image = bitmap.cgImage, let pixels = straightARGB(image),
                              let webp = WebPLossless.encode(width: image.width, height: image.height, pixels: pixels) else { throw CommandError.failed("Cette image est trop grande pour être convertie en WebP.") }
                        output = webp
                    } else {
                        let type: NSBitmapImageRep.FileType = selectedFormat == "PNG" ? .png : selectedFormat == "JPEG" ? .jpeg : .tiff
                        guard let result = bitmap.representation(using: type, properties: [.compressionFactor: 0.92]) else { throw CommandError.failed("Cette conversion n’est pas disponible.") }; output = result
                    }
                    let directory = AppPaths.support.appendingPathComponent("Conversions", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6)).appendingPathExtension(selectedFormat.lowercased())
                    try output.write(to: url, options: .atomic)
                    return url
                }.value
                model.shelf.add([destination]); error = nil; model.notify("Conversion terminée")
                // Output remains in Conversions until the shelf finishes its copy; kept for recovery.
            } catch { self.error = error.localizedDescription }
        }
    }
}

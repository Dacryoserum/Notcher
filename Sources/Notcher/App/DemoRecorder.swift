import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import NotcherCore

/// `--record-demo <file.mov>`: films a scripted tour of Notcher for the README.
///
/// The interface is the real one (the same `NotchView` and services as the app); what surrounds it is a
/// stage: a 14-inch MacBook screen drawn in a window, with a menu bar and a Dock, and a camera that zooms
/// in and out. The window is parked off the edge of the real screen, so recording disturbs nothing. Everything shown is made up here. The recorder runs on its own
/// preferences and refuses to start unless NOTCHER_DATA_DIR points to a scratch folder, so it can never
/// read or change the user's data. The window is filmed by ScreenCaptureKit at 60 frames a second, which
/// needs the Screen Recording permission for the terminal that starts it.
/// Use Scripts/record-demo.sh rather than calling it directly.
@MainActor final class DemoRecorder {
    private static var current: DemoRecorder?
    static func run(output: String) {
        guard ProcessInfo.processInfo.environment["NOTCHER_DATA_DIR"] != nil else {
            fputs("--record-demo needs NOTCHER_DATA_DIR set to a scratch folder. Use Scripts/record-demo.sh.\n", stderr)
            exit(2)
        }
        let recorder = DemoRecorder(output: URL(fileURLWithPath: output))
        current = recorder
        recorder.start()
    }

    /// A 14-inch MacBook Pro at its default resolution, in points.
    static let scene = CGSize(width: 1512, height: 982)
    private static let suite = "fr.notcher.demo"
    private let output: URL
    private let model: AppModel
    private let director = DemoDirector()
    private var window: NSWindow?
    private var stage: NSView?
    private var recorder: ScreenRecorder?
    private var startedAt = Date()
    private let french = Bundle.main.preferredLocalizations.first == "fr"

    private init(output: URL) {
        self.output = output
        UserDefaults().removePersistentDomain(forName: Self.suite)
        let preferences = Preferences(defaults: UserDefaults(suiteName: Self.suite) ?? .standard)
        preferences.codexEnabled = true
        preferences.openMode = .touch
        model = AppModel(preferences: preferences)
        model.notchWidth = 186; model.notchHeight = 32
        Haptics.enabled = false
    }

    private func start() {
        seed()
        // Two layers: the screen, which the camera scales, and the captions, which it leaves alone.
        let stage = NSHostingView(rootView: DemoStage(model: model, director: director).preferredColorScheme(.dark))
        let overlay = NSHostingView(rootView: DemoOverlay(director: director).preferredColorScheme(.dark))
        let frame = NSRect(origin: .zero, size: Self.scene)
        let container = NSView(frame: frame)
        container.wantsLayer = true; container.layer?.masksToBounds = true; container.layer?.backgroundColor = NSColor.black.cgColor
        stage.frame = frame; overlay.frame = frame
        container.addSubview(stage); container.addSubview(overlay)
        self.stage = stage
        // Borderless: not constrained to the screen, and filmed without a title bar or shadow.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container; window.hasShadow = false; window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        // Parked past the right edge of the screen, with a sliver left on it so macOS keeps drawing it:
        // nothing covers the desktop while the film is made, and there is nothing to close.
        let screen = NSScreen.main?.frame ?? frame
        window.setFrameOrigin(NSPoint(x: screen.maxX - 2, y: screen.minY))
        window.orderFrontRegardless()
        self.window = window
        let scale = window.backingScaleFactor
        Task { @MainActor in
            // Let thumbnails and the first layout settle before the first frame.
            try? await Task.sleep(for: .seconds(2))
            guard window.occlusionState.contains(.visible) else {
                fputs("The recording window is not being drawn on this Mac; nothing was recorded.\n", stderr)
                exit(3)
            }
            do {
                let recorder = try ScreenRecorder(url: output, width: Int(Self.scene.width * scale), height: Int(Self.scene.height * scale))
                try await recorder.start(windowID: CGWindowID(window.windowNumber))
                self.recorder = recorder
            } catch {
                fputs("Cannot record: \(error.localizedDescription)\nAllow Screen Recording for your terminal in System Settings → Privacy & Security.\n", stderr)
                exit(1)
            }
            startedAt = Date()
            await play()
            await recorder?.stop()
            await stills()
            UserDefaults().removePersistentDomain(forName: Self.suite)
            print(output.path)
            fputs("\(recorder?.frames ?? 0) frames\n", stderr)
            exit(0)
        }
    }

    // MARK: Script

    private func at(_ seconds: Double) async {
        let delay = seconds - Date().timeIntervalSince(startedAt)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }
    private func say(_ english: String, _ french: String) { withAnimation(.easeOut(duration: 0.4)) { director.caption = self.french ? french : english } }
    private func hush() { withAnimation(.easeOut(duration: 0.4)) { director.caption = nil } }
    private var spring: Animation { .spring(response: 0.5, dampingFraction: 0.8) }
    /// The camera: scales the whole stage layer about the top centre of the screen, where the notch is.
    /// Done on the layer, by the window server, so every view moves as one picture.
    private func zoom(_ value: CGFloat, duration: Double = 1.5) {
        guard let layer = stage?.layer else { return }
        let size = Self.scene
        // The layer's origin is its bottom-left corner; the top centre is (width / 2, height).
        let target = CATransform3DConcat(CATransform3DMakeScale(value, value, 1),
                                         CATransform3DMakeTranslation(size.width / 2 * (1 - value), size.height * (1 - value), 0))
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = (layer.presentation() ?? layer).transform
            animation.toValue = target
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.25, 1)
            layer.add(animation, forKey: "camera")
        } else { layer.removeAnimation(forKey: "camera") }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
    }
    private func open(tab: NotchTab? = nil) {
        withAnimation(spring) { model.hovering = false; model.expand(tab: tab); model.presentationExpanded = true }
    }
    private func close() {
        withAnimation(spring) { model.expanded = false; model.presentationExpanded = false; model.pinned = false }
    }
    private func select(_ tab: NotchTab) {
        withAnimation(.easeOut(duration: 0.14)) { model.tab = tab }
        // A tab chosen in the same turn as a pointer click was sometimes drawn only at the model's next
        // change, seconds later. Announcing the model once more, after the value is set, draws it now.
        DispatchQueue.main.async { [model] in model.objectWillChange.send() }
    }

    // Where things are on the stage, in scene points.
    private var panelLeft: CGFloat { (Self.scene.width - model.expandedWidth) / 2 }
    private var navigationY: CGFloat { model.notchHeight + 12 + 19 }
    private func tab(_ index: Int) -> CGPoint {
        let width = (model.expandedWidth - 64 - 8 * 5 - 3 * 32 - 2) / 5
        return CGPoint(x: panelLeft + 32 + CGFloat(index) * (width + 5) + width / 2, y: navigationY)
    }
    private var chevron: CGPoint { CGPoint(x: panelLeft + model.expandedWidth - 32 - 16, y: navigationY) }
    private func card(_ index: Int) -> CGPoint {
        let width = (model.expandedWidth - 64 - 30) / 4
        return CGPoint(x: panelLeft + 32 + CGFloat(index) * (width + 10) + width / 2, y: 238)
    }
    private var notch: CGPoint { CGPoint(x: Self.scene.width / 2 + 8, y: 15) }

    private func play() async {
        // The whole screen, as it is without Notcher.
        await at(0.8); say("The notch on your Mac just sits there", "L’encoche de ton Mac ne sert à rien")
        await at(3.6)
        setTrack(playing: true)
        withAnimation(spring) { model.showActivity(.init(symbol: "music.note", title: Self.song), seconds: 3) }
        say("Notcher brings it to life", "Notcher lui donne vie")

        // Open it, at its real size.
        await at(7.0); say("Hover it, then click", "Survole-la, puis clique")
        director.show(at: CGPoint(x: 860, y: 600))
        await director.move(to: notch, duration: 1.2)
        withAnimation(spring) { model.hovering = true }
        await at(9.2); director.click(); open()

        // Close up on the panel.
        await at(11.2); zoom(1.8)
        say("An overview made of widgets you arrange", "Un aperçu fait de widgets que tu disposes")
        await at(13.4); await director.move(to: CGPoint(x: panelLeft + 229, y: 290), duration: 0.8)
        director.click(); setTrack(playing: false)
        await at(15.2); director.click(); setTrack(playing: true)

        await at(16.8); await director.move(to: tab(1), duration: 0.6); director.click(); select(.files)
        say("Drop files on the notch to keep them at hand", "Dépose des fichiers sur l’encoche pour les garder sous la main")
        await at(19.4); await director.move(to: card(0), duration: 0.6); director.click()
        model.shelf.selection = Set(model.shelf.items.prefix(1).map(\.id))
        say("Real previews, multi-select, drag several out at once", "Vraies miniatures, sélection multiple, glisser à plusieurs")
        await at(21.0); await director.move(to: card(2), duration: 0.5); director.key("⌘"); director.click()
        if model.shelf.items.count > 2 { model.shelf.selection.insert(model.shelf.items[2].id) }
        await at(23.2); director.key("⌫"); model.removeFromShelf(model.shelf.selection)
        say("Every removal can be undone", "Chaque retrait s’annule")
        await at(24.6)
        await director.move(to: CGPoint(x: Self.scene.width / 2 + 40, y: model.notchHeight + 84 + model.pageHeight - 38), duration: 0.6)
        director.click(); model.undoShelfRemoval()

        await at(26.6); await director.move(to: tab(2), duration: 0.6); director.click(); select(.notes)
        say("Text sheets for whatever is on your mind", "Des fiches texte pour ce qui te passe par la tête")
        await type(french ? "\n- Rappeler Léa pour la démo" : "\n- Call Sam about the demo", over: 2.2)
        await at(31.0); await director.move(to: tab(3), duration: 0.5); director.click(); select(.agents)
        say("Claude Code and Codex quotas at a glance", "Tes quotas Claude Code et Codex d’un coup d’œil")
        await at(34.2); await director.move(to: tab(4), duration: 0.5); director.click(); select(.tools)
        say("A Pomodoro, a mirror, an image converter and more", "Un Pomodoro, un miroir, un convertisseur d’images…")
        await at(36.4); await director.move(to: CGPoint(x: panelLeft + 126, y: 307), duration: 0.6)
        director.click()
        model.focus.clock.start(at: Date()); model.focus.now = Date(); model.focus.start()

        // Closed again: what the notch says by itself.
        await at(38.6); await director.move(to: chevron, duration: 0.7); director.click(); close(); zoom(2.7, duration: 1.3)
        say("…which keeps counting in the notch", "…qui continue dans l’encoche")
        await director.move(to: CGPoint(x: 1010, y: 300), duration: 0.9); director.hide()
        await at(42.0)
        withAnimation(spring) {
            model.showActivity(.init(symbol: "asterisk", title: "", color: Theme.orange, artwork: ClaudeMark.icon, mark: "checkmark.circle.fill", markColor: Theme.green), seconds: 3.2)
        }
        say("It tells you when Claude Code is done", "Il te dit quand Claude Code a fini")
        await at(45.8)
        let name = "AirPods Pro"
        withAnimation(spring) {
            model.showActivity(.init(symbol: Accessory.symbol(productID: nil, name: name), title: name, artwork: Accessory.image(productID: nil, name: name),
                                     trailing: "85 %", details: [L("G %lld %%", 85), L("D %lld %%", 90), L("Boîtier %lld %%", 60)]), seconds: 3.4)
        }
        say("…and when your AirPods connect", "…et quand tes AirPods se connectent")

        // Step back to the whole screen, and sign.
        await at(49.6); hush(); zoom(1, duration: 1.6)
        await at(51.6); withAnimation(.easeInOut(duration: 0.9)) { director.endCard = true }
        await at(55.0)
    }

    /// Clean pictures for the README, taken once the film is over: no caption, no pointer.
    private func stills() async {
        guard let recorder else { return }
        director.pointerVisible = false; director.caption = nil; director.keycap = nil; director.endCard = false
        model.focus.clock.reset(duration: nil); model.dismissToast()
        func shoot(_ name: String) async {
            try? await Task.sleep(for: .seconds(0.9))
            guard let image = await recorder.screenshot() else { return }
            let url = output.deletingLastPathComponent().appendingPathComponent(name + ".png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        }
        var instant = Transaction(); instant.disablesAnimations = true
        zoom(1, duration: 0)
        withTransaction(instant) { model.tab = .home; model.expanded = true; model.presentationExpanded = true }
        await shoot("screen")
        zoom(1.8, duration: 0)
        await shoot("overview")
        withTransaction(instant) { model.tab = .files; model.shelf.selection = Set(model.shelf.items.enumerated().filter { $0.offset == 0 || $0.offset == 2 }.map(\.element.id)) }
        await shoot("shelf")
        withTransaction(instant) { model.shelf.selection = []; model.tab = .notes }
        await shoot("notes")
        withTransaction(instant) { model.tab = .agents }
        await shoot("agents")
    }

    // MARK: Made-up content

    private static let song = "Northern Lights"
    private let cover: NSImage = DemoArt.cover()
    private var position = 64.0
    private var playingSince: Date?
    private var ticker: Timer?
    /// The demo player only knows what it is told: while it plays, its position is refreshed every second.
    private func setTrack(playing: Bool) {
        if let since = playingSince { position += Date().timeIntervalSince(since) }
        playingSince = playing ? Date() : nil
        publishTrack()
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.publishTrack() } }
        }
    }
    private func publishTrack() {
        let elapsed = position + (playingSince.map { Date().timeIntervalSince($0) } ?? 0)
        model.media.showDemo(NowPlaying(title: Self.song, artist: "Aurora Fields", album: "Polar Nights", application: "Music", bundleIdentifier: "com.apple.Music",
                                        playing: playingSince != nil, duration: 214, elapsed: elapsed, artwork: nil), artwork: cover)
    }
    private func type(_ addition: String, over duration: Double) async {
        let base = model.notes.selected?.text ?? ""
        let pause = duration / Double(max(1, addition.count))
        var typed = ""
        for character in addition {
            typed.append(character)
            model.notes.update(text: base + typed)
            try? await Task.sleep(for: .seconds(pause))
        }
    }
    private func seed() {
        let now = Date()
        let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        model.calendar.authorized = true
        model.calendar.events = [
            CalendarItem(id: "1", title: french ? "Revue de design" : "Design review", start: tomorrow.addingTimeInterval(10 * 3600), end: tomorrow.addingTimeInterval(11 * 3600), allDay: false,
                         calendarName: "Work", color: .systemBlue, meeting: URL(string: "https://meet.example.com/demo")),
            CalendarItem(id: "2", title: french ? "Déjeuner avec Léa" : "Lunch with Sam", start: tomorrow.addingTimeInterval(12.5 * 3600), end: tomorrow.addingTimeInterval(14 * 3600), allDay: false,
                         calendarName: "Home", color: .systemOrange, meeting: nil)
        ]
        model.agents.claudeInstalled = true
        model.agents.claude = AgentUsage(provider: "claude", windows: [
            UsageWindow(id: "five_hour", title: "Session", usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 900)),
            UsageWindow(id: "seven_day", title: french ? "Semaine" : "Week", usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86_400))
        ], model: "Claude Opus", capturedAt: now)
        model.agents.codex = AgentUsage(provider: "codex", windows: [
            UsageWindow(id: "primary", title: french ? "5 heures" : "5 hours", usedPercent: 27, resetsAt: now.addingTimeInterval(3 * 3600)),
            UsageWindow(id: "secondary", title: french ? "Semaine" : "Week", usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86_400))
        ], model: "gpt-5-codex", capturedAt: now)
        model.system.volume = 0.62; model.system.battery = 78
        model.notes.update(title: french ? "Lancement" : "Launch")
        model.notes.update(text: french
            ? "Lancement v1.3\n\n- Vérifier la notarisation\n- Captures pour le site\n- Annoncer sur le forum"
            : "v1.3 launch\n\n- Check notarization\n- Screenshots for the site\n- Post on the forum")
        for task in french ? ["Relire le README", "Enregistrer la démo", "Publier la version"] : ["Proofread the README", "Record the demo", "Publish the release"] {
            model.focus.addTask(task)
        }
        if let first = model.focus.tasks.first { model.focus.toggleTask(first.id) }
        model.toolTab = .focus
        model.shelf.start(retentionHours: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-demo-files-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = DemoArt.files(in: folder, french: french)
        model.shelf.add(["notes", "quote", "mockup", "moodboard"].compactMap { files[$0] })
    }
}

/// What the camera shows besides the app: the caption, the pointer, a key being pressed, the zoom.
@MainActor final class DemoDirector: ObservableObject {
    @Published var caption: String?
    @Published var pointer = CGPoint(x: 700, y: 330)
    @Published var pointerVisible = false
    @Published var pressed = false
    @Published var ripple = 0
    @Published var keycap: String?
    @Published var endCard = false
    private var keyTask: Task<Void, Never>?
    func show(at point: CGPoint) { pointer = point; withAnimation(.easeOut(duration: 0.3)) { pointerVisible = true } }
    func hide() { withAnimation(.easeOut(duration: 0.3)) { pointerVisible = false } }
    func move(to point: CGPoint, duration: Double) async {
        withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: duration)) { pointer = point }
        try? await Task.sleep(for: .seconds(duration + 0.05))
    }
    func click() {
        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
        ripple += 1
        Task { try? await Task.sleep(for: .milliseconds(140)); withAnimation(.easeOut(duration: 0.12)) { self.pressed = false } }
    }
    func key(_ value: String) {
        keyTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { keycap = value }
        keyTask = Task { try? await Task.sleep(for: .seconds(1.2)); guard !Task.isCancelled else { return }; withAnimation(.easeOut(duration: 0.25)) { self.keycap = nil } }
    }
}

// MARK: - Stage

/// The MacBook screen: everything here is scaled by the camera.
private struct DemoStage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var director: DemoDirector
    private var french: Bool { Bundle.main.preferredLocalizations.first == "fr" }
    private static let backdrop: NSImage = DemoArt.wallpaper(size: DemoRecorder.scene)
    var body: some View {
        ZStack(alignment: .top) {
            Image(nsImage: Self.backdrop).resizable()
            dock
            menuBar
            NotchView(model: model)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.targetSize)
            pointer
        }
        .frame(width: DemoRecorder.scene.width, height: DemoRecorder.scene.height)
    }
    private var menuBar: some View {
        HStack(spacing: 20) {
            Image(systemName: "apple.logo").font(.system(size: 15))
            Text(verbatim: "Finder").fontWeight(.bold)
            ForEach(french ? ["Fichier", "Édition", "Présentation", "Aller", "Fenêtre", "Aide"] : ["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text(verbatim: $0) }
            Spacer()
            Group {
                Image(systemName: "battery.75percent").font(.system(size: 17))
                Image(systemName: "wifi")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
            }.font(.system(size: 14))
            Text(Date(), format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
        .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.95))
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        .padding(.horizontal, 22).frame(height: model.notchHeight)
        .background(.black.opacity(0.16))
    }
    private var dock: some View {
        let apps = ["com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Music", "com.apple.Notes", "com.apple.iCal", "com.apple.Photos", "com.apple.systempreferences"]
        return VStack {
            Spacer()
            HStack(spacing: 6) {
                ForEach(apps, id: \.self) { identifier in
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                        VStack(spacing: 2) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).frame(width: 52, height: 52)
                            Circle().fill(.white.opacity(["com.apple.finder", "com.apple.Music"].contains(identifier) ? 0.8 : 0)).frame(width: 4, height: 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.18)))
            .padding(.bottom, 8)
        }
    }
    private var pointer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ZStack(alignment: .topLeading) {
                Circle().stroke(.white.opacity(0.75), lineWidth: 2).frame(width: 34, height: 34).offset(x: -17, y: -17)
                    .modifier(Ripple(trigger: director.ripple))
                Image(nsImage: NSCursor.arrow.image).resizable().interpolation(.high)
                    .frame(width: NSCursor.arrow.image.size.width, height: NSCursor.arrow.image.size.height)
                    .offset(x: -NSCursor.arrow.hotSpot.x, y: -NSCursor.arrow.hotSpot.y)
                    .scaleEffect(director.pressed ? 0.86 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                if let key = director.keycap {
                    Text(verbatim: key).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(minWidth: 36, minHeight: 36).padding(.horizontal, 4)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
                        .offset(x: 22, y: 20)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .offset(x: director.pointer.x, y: director.pointer.y)
            .opacity(director.pointerVisible ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

/// Captions and the end card: drawn over the stage, never scaled by the camera.
private struct DemoOverlay: View {
    @ObservedObject var director: DemoDirector
    private var french: Bool { Bundle.main.preferredLocalizations.first == "fr" }
    var body: some View {
        ZStack {
            caption
            if director.endCard { endCard.transition(.opacity) }
        }
        .frame(width: DemoRecorder.scene.width, height: DemoRecorder.scene.height)
    }
    private var caption: some View {
        VStack {
            Spacer()
            if let text = director.caption {
                Text(verbatim: text)
                    .font(.system(size: 31, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 30).padding(.vertical, 15)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                    .id(text)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            }
        }.padding(.bottom, 96)
    }
    private var endCard: some View {
        ZStack {
            Color.black.opacity(0.62)
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 150, height: 150)
                Text(verbatim: "Notcher").font(.system(size: 76, weight: .bold, design: .rounded))
                Text(verbatim: french ? "Ton encoche, enfin utile." : "Your notch, finally useful.").font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Text(verbatim: french ? "Gratuit · macOS 14 et plus" : "Free · macOS 14 and later").font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(0.55)).padding(.top, 6)
            }.foregroundStyle(.white)
        }
    }
}

/// A ring that grows and fades at each click.
private struct Ripple: ViewModifier {
    let trigger: Int
    @State private var progress: CGFloat = 1
    func body(content: Content) -> some View {
        content.scaleEffect(0.4 + progress * 0.9).opacity(Double(1 - progress))
            .onChange(of: trigger) { _, _ in
                progress = 0
                withAnimation(.easeOut(duration: 0.45)) { progress = 1 }
            }
    }
}

// MARK: - Made-up pictures

/// Wallpaper, cover and files drawn on the spot, so the demo shows no one's real content.
@MainActor enum DemoArt {
    /// A desktop picture: deep blue with soft coloured light, blurred once with Core Image.
    static func wallpaper(size: CGSize) -> NSImage {
        let sharp = NSImage(size: size, flipped: true) { rect in
            NSGradient(colors: [NSColor(red: 0.10, green: 0.16, blue: 0.36, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.14, alpha: 1)])?.draw(in: rect, angle: -90)
            let lights: [(NSColor, CGFloat, CGFloat, CGFloat)] = [
                (NSColor(red: 0.20, green: 0.62, blue: 0.98, alpha: 0.75), 0.12, 0.30, 0.42),
                (NSColor(red: 0.58, green: 0.36, blue: 0.96, alpha: 0.70), 0.86, 0.42, 0.46),
                (NSColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 0.55), 0.62, 1.02, 0.40),
                (NSColor(red: 0.35, green: 0.90, blue: 0.72, alpha: 0.45), 0.26, 0.98, 0.34)
            ]
            for (color, x, y, radius) in lights {
                color.setFill()
                let r = radius * rect.height
                NSBezierPath(ovalIn: NSRect(x: x * rect.width - r, y: y * rect.height - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        guard let tiff = sharp.tiffRepresentation, let input = CIImage(data: tiff),
              let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 190])?.outputImage?.cropped(to: input.extent),
              let image = CIContext().createCGImage(blurred, from: input.extent) else { return sharp }
        return NSImage(cgImage: image, size: size)
    }
    static func cover() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.12, green: 0.20, blue: 0.45, alpha: 1), NSColor(red: 0.30, green: 0.80, blue: 0.65, alpha: 1)])?.draw(in: rect, angle: 65)
            for (index, alpha) in [0.35, 0.22, 0.14].enumerated() {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: 120 + index * 40))
                path.curve(to: NSPoint(x: 300, y: 170 + index * 30), controlPoint1: NSPoint(x: 90, y: 230 + index * 20), controlPoint2: NSPoint(x: 200, y: 60 + index * 30))
                path.lineWidth = 26; NSColor(white: 1, alpha: alpha).setStroke(); path.stroke()
            }
            return true
        }
    }
    private static func picture(_ colors: [NSColor], size: NSSize, draw: ((NSRect) -> Void)? = nil) -> Data? {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 120)
            draw?(rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    /// The demo's files, by role: "moodboard", "mockup", "quote", "notes".
    static func files(in folder: URL, french: Bool) -> [String: URL] {
        var urls: [String: URL] = [:]
        func write(_ role: String, _ name: String, _ data: Data?) {
            guard let data else { return }
            let url = folder.appendingPathComponent(name)
            if (try? data.write(to: url)) != nil { urls[role] = url }
        }
        write("moodboard", french ? "Planche.png" : "Moodboard.png", picture([.systemPink, .systemOrange, .systemYellow], size: NSSize(width: 1200, height: 900)) { _ in
            for index in 0..<3 {
                NSColor(white: 1, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 80 + CGFloat(index) * 360, y: 220, width: 320, height: 460), xRadius: 30, yRadius: 30).fill()
            }
        })
        write("mockup", french ? "Maquette.png" : "Mockup.png", picture([.systemIndigo, .systemTeal], size: NSSize(width: 1400, height: 900)) { rect in
            NSColor(white: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 120, dy: 110), xRadius: 40, yRadius: 40).fill()
            NSColor(red: 0.70, green: 0.93, blue: 0.66, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 220, y: 560, width: 520, height: 80), xRadius: 40, yRadius: 40).fill()
        })
        // A one-page PDF: Quick Look draws its page as the thumbnail.
        let pdf = NSMutableData()
        if let consumer = CGDataConsumer(data: pdf as CFMutableData) {
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            if let context = CGContext(consumer: consumer, mediaBox: &box, nil) {
                context.beginPDFPage(nil)
                context.setFillColor(NSColor.white.cgColor); context.fill(box)
                context.setFillColor(NSColor(red: 0.12, green: 0.20, blue: 0.45, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 700, width: 595, height: 142))
                context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
                for line in 0..<14 { context.fill(CGRect(x: 60, y: 620 - line * 34, width: line % 4 == 3 ? 300 : 475, height: 12)) }
                context.endPDFPage(); context.closePDF()
            }
        }
        write("quote", french ? "Devis.pdf" : "Quote.pdf", pdf as Data)
        write("notes", french ? "Notes de version.md" : "Release notes.md",
              Data((french ? "# Notcher 1.3\n\n- Miniatures dans le dépôt\n- Raccourci personnalisable\n" : "# Notcher 1.3\n\n- Shelf thumbnails\n- Custom shortcut\n").utf8))
        return urls
    }
}

// MARK: - Capture

/// Films one window with ScreenCaptureKit and encodes it as it comes. Frames arrive from the window server,
/// so the main thread stays free for the animations being filmed.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "fr.notcher.demo.capture")
    private let width: Int, height: Int
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var first: CMTime?
    private var last = CMTime.zero
    private(set) var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        self.width = width; self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // A lightly compressed master; Scripts/record-demo.sh makes the files that are published from it.
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000, AVVideoExpectedSourceFrameRateKey: 60]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        super.init()
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }
    private var configuration: SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }
    func start(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == windowID }) else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        self.filter = filter
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
              let image = buffer.imageBuffer else { return }
        let stamp = buffer.presentationTimeStamp
        if first == nil { first = stamp }
        let time = stamp - (first ?? stamp)
        guard input.isReadyForMoreMediaData, frames == 0 || time > last else { return }
        if adaptor.append(image, withPresentationTime: time) { last = time; frames += 1 }
    }
    func stop() async {
        try? await stream?.stopCapture()
        queue.sync {}
        input.markAsFinished()
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()
    }
    /// One picture of the window as it is now.
    func screenshot() async -> CGImage? {
        guard let filter else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

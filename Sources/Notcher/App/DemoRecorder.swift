import AppKit
import AVFoundation
import SwiftUI
import NotcherCore

/// `--record-demo <file.mp4>`: plays a scripted tour of Notcher on a fake desktop and records it, for the
/// README. Everything it shows is made up here; it runs on its own preferences and refuses to start unless
/// NOTCHER_DATA_DIR points to a scratch folder, so it can never read or change the user's data.
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

    static let scene = CGSize(width: 960, height: 540)
    /// 1.5× the scene: sharp enough for a README, and light enough to capture about 30 times a second.
    static let pixels = (width: 1440, height: 810)
    private static let suite = "fr.notcher.demo"
    private let output: URL
    private let model: AppModel
    private let director = DemoDirector()
    private var window: NSWindow?
    private var view: NSView?
    /// The same scene without caption or pointer, kept in step with the model, for clean screenshots.
    private var stillView: NSView?
    private var stillWindow: NSWindow?
    private var writer: FrameWriter?
    private var capturing: Task<Void, Never>?
    private var startedAt = Date()
    private let french = Bundle.main.preferredLocalizations.first == "fr"

    private init(output: URL) {
        self.output = output
        UserDefaults().removePersistentDomain(forName: Self.suite)
        let preferences = Preferences(defaults: UserDefaults(suiteName: Self.suite) ?? .standard)
        preferences.codexEnabled = true
        model = AppModel(preferences: preferences)
        model.notchWidth = 190; model.notchHeight = 32
        Haptics.enabled = false
    }

    private func start() {
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingView(rootView: DemoScene(model: model, director: director).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: Self.scene)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Notcher demo"; window.contentView = host; window.center(); window.orderFrontRegardless()
        self.window = window; view = host
        let clean = NSHostingView(rootView: DemoScene(model: model, director: director, overlays: false).preferredColorScheme(.dark))
        clean.frame = host.frame
        let offscreen = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: host.frame.width, height: host.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        offscreen.contentView = clean; offscreen.orderFrontRegardless()
        stillWindow = offscreen; stillView = clean
        seed()
        Task { @MainActor in
            // Let thumbnails and the first layout settle before the first frame.
            try? await Task.sleep(for: .seconds(1.5))
            do { writer = try FrameWriter(url: output, width: Self.pixels.width, height: Self.pixels.height) }
            catch { fputs("Cannot write \(output.path): \(error.localizedDescription)\n", stderr); exit(1) }
            startedAt = Date()
            // Each capture is followed by a pause: a timer firing back to back would starve the run loop,
            // and SwiftUI would never get to apply the script's changes before the next frame.
            capturing = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let begin = Date()
                    self?.capture()
                    let rest = max(0.008, 1.0 / 30 - Date().timeIntervalSince(begin))
                    try? await Task.sleep(for: .seconds(rest))
                }
            }
            await play()
            capturing?.cancel()
            await writer?.finish()
            UserDefaults().removePersistentDomain(forName: Self.suite)
            print(output.path)
            fputs(String(format: "%d frames, %.0f ms each\n", frames, captureTime / Double(max(1, frames)) * 1000), stderr)
            exit(0)
        }
    }

    // MARK: Frames

    private func render(_ source: NSView? = nil) -> NSBitmapImageRep? {
        guard let view = source ?? view, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Self.pixels.width, pixelsHigh: Self.pixels.height, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    private var frames = 0, captureTime = 0.0
    private func capture() {
        let begin = Date()
        guard let image = render()?.cgImage, writer?.append(image, seconds: begin.timeIntervalSince(startedAt)) == true else { return }
        frames += 1; captureTime += Date().timeIntervalSince(begin)
    }
    /// A still of the current moment, next to the video: the README's screenshots.
    private func still(_ name: String) {
        guard let data = render(stillView)?.representation(using: .png, properties: [:]) else { return }
        let url = output.deletingLastPathComponent().appendingPathComponent(name + ".png")
        try? data.write(to: url)
    }

    // MARK: Script

    private func at(_ seconds: Double) async {
        let delay = seconds - Date().timeIntervalSince(startedAt)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }
    private func say(_ english: String, _ french: String) { withAnimation(.easeOut(duration: 0.35)) { director.caption = self.french ? french : english } }
    private var spring: Animation { .spring(response: 0.48, dampingFraction: 0.8) }

    private func play() async {
        let panelLeft = (Self.scene.width - model.expandedWidth) / 2
        let tabWidth = (model.expandedWidth - 64 - 8 * 5 - 3 * 32 - 2) / 5
        func tab(_ index: Int) -> CGPoint { CGPoint(x: panelLeft + 32 + CGFloat(index) * (tabWidth + 5) + tabWidth / 2, y: model.notchHeight + 12 + 19) }
        let collapse = CGPoint(x: panelLeft + model.expandedWidth - 32 - 16, y: model.notchHeight + 12 + 19)
        let cardWidth = (model.expandedWidth - 64 - 30) / 4
        func card(_ index: Int) -> CGPoint { CGPoint(x: panelLeft + 32 + CGFloat(index) * (cardWidth + 10) + cardWidth / 2, y: 236) }

        await at(0.4); say("Notcher turns the notch into a workspace", "Notcher transforme le notch en espace de travail")
        await at(2.2)
        model.media.showDemo(track(playing: true, elapsed: 64), artwork: cover)
        withAnimation(spring) { model.showActivity(.init(symbol: "music.note", title: Self.song), seconds: 2.6) }
        say("Your music lives in it", "Ta musique y vit")
        await at(3.0); keepPlaying()
        await at(5.6); say("Hover or click to open it", "Survole ou clique pour l’ouvrir")
        director.show(at: CGPoint(x: 700, y: 330))
        await director.move(to: CGPoint(x: Self.scene.width / 2 + 10, y: 14), duration: 0.9)
        await at(6.9); director.click()
        withAnimation(spring) { model.expanded = true; model.presentationExpanded = true }
        await at(7.6); say("Widgets you arrange yourself", "Des widgets que tu disposes toi-même")
        await at(8.6); still("overview")

        await director.move(to: tab(1), duration: 0.6)
        director.click(); withAnimation(.easeOut(duration: 0.14)) { model.tab = .files }
        say("A shelf for the files you are moving around", "Un dépôt pour les fichiers en transit")
        await at(11.0)
        await director.move(to: card(0), duration: 0.5); director.click()
        model.shelf.selection = [model.shelf.items[0].id]
        await at(11.9)
        await director.move(to: card(2), duration: 0.45); director.key("⌘"); director.click()
        model.shelf.selection.insert(model.shelf.items[2].id)
        await at(12.8); still("shelf")
        say("Real previews, Quick Look, drag several files at once", "Vraies miniatures, Quick Look, plusieurs fichiers d’un coup")
        await at(14.6); director.key("⌫"); model.removeFromShelf(model.shelf.selection)
        say("And every removal can be undone", "Et chaque retrait s’annule")
        await at(15.8)
        await director.move(to: CGPoint(x: Self.scene.width / 2 + 52, y: model.notchHeight + 12 + 38 + 14 + model.pageHeight + 20 - 8 - 16), duration: 0.6)
        director.click(); model.undoShelfRemoval()

        await at(17.6); await director.move(to: tab(2), duration: 0.6)
        director.click(); withAnimation(.easeOut(duration: 0.14)) { model.tab = .notes }
        say("Text sheets, always one click away", "Des fiches texte, à un clic")
        await at(19.6); still("notes")
        await director.move(to: tab(3), duration: 0.5)
        director.click(); withAnimation(.easeOut(duration: 0.14)) { model.tab = .agents }
        say("Your Claude Code and Codex quotas", "Tes quotas Claude Code et Codex")
        await at(21.8); still("agents")
        await director.move(to: collapse, duration: 0.6)
        director.click()
        withAnimation(spring) { model.expanded = false; model.presentationExpanded = false }
        await director.move(to: CGPoint(x: 760, y: 360), duration: 0.8); director.hide()

        await at(24.0)
        withAnimation(spring) {
            model.showActivity(.init(symbol: "asterisk", title: "", color: Theme.orange, artwork: ClaudeMark.icon, mark: "checkmark.circle.fill", markColor: Theme.green), seconds: 3)
        }
        say("It tells you when Claude Code is done", "Il te dit quand Claude Code a fini")
        await at(27.6)
        let name = "AirPods Pro"
        withAnimation(spring) {
            model.showActivity(.init(symbol: Accessory.symbol(productID: nil, name: name), title: name, artwork: Accessory.image(productID: nil, name: name),
                                     trailing: "85 %", details: [L("G %lld %%", 85), L("D %lld %%", 90), L("Boîtier %lld %%", 60)]), seconds: 3.4)
        }
        say("…and your AirPods, the moment they connect", "…et tes AirPods, dès qu’ils se connectent")
        await at(30.0); still("headphones")
        await at(31.4); say("Notcher · free for macOS 14 and later", "Notcher · gratuit pour macOS 14 et plus")
        await at(34.0)
    }

    // MARK: Made-up content

    private static let song = "Northern Lights"
    private let cover: NSImage = DemoArt.cover()
    private var playingSince = Date()
    private func track(playing: Bool, elapsed: Double) -> NowPlaying {
        NowPlaying(title: Self.song, artist: "Aurora Fields", album: "Polar Nights", application: "Music", bundleIdentifier: "com.apple.Music",
                   playing: playing, duration: 214, elapsed: elapsed, artwork: nil)
    }
    /// The demo player only knows what it is told: its position is refreshed every second.
    private func keepPlaying() {
        playingSince = Date()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.media.showDemo(self.track(playing: true, elapsed: 64 + Date().timeIntervalSince(self.playingSince)), artwork: self.cover)
            }
        }
    }
    private func seed() {
        let now = Date()
        model.calendar.authorized = true
        let day = Calendar.current.startOfDay(for: now)
        model.calendar.events = [
            CalendarItem(id: "1", title: french ? "Revue de design" : "Design review", start: now.addingTimeInterval(25 * 60), end: now.addingTimeInterval(55 * 60), allDay: false,
                         calendarName: "Work", color: .systemBlue, meeting: URL(string: "https://meet.example.com/demo")),
            CalendarItem(id: "2", title: french ? "Déjeuner avec Léa" : "Lunch with Sam", start: day.addingTimeInterval(36 * 3600 + 1800), end: day.addingTimeInterval(38 * 3600), allDay: false,
                         calendarName: "Home", color: .systemOrange, meeting: nil)
        ]
        model.agents.claudeInstalled = true
        model.agents.claude = AgentUsage(provider: "claude", windows: [
            UsageWindow(id: "five_hour", title: french ? "Session" : "Session", usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 900)),
            UsageWindow(id: "seven_day", title: french ? "Semaine" : "Week", usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86_400))
        ], model: "Claude Opus", capturedAt: now)
        model.agents.codex = AgentUsage(provider: "codex", windows: [
            UsageWindow(id: "primary", title: french ? "5 heures" : "5 hours", usedPercent: 27, resetsAt: now.addingTimeInterval(3 * 3600)),
            UsageWindow(id: "secondary", title: french ? "Semaine" : "Week", usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86_400))
        ], model: "gpt-5-codex", capturedAt: now)
        model.system.volume = 0.62; model.system.battery = 78
        model.notes.update(title: french ? "Lancement" : "Launch")
        model.notes.update(text: french
            ? "Lancement v1.3\n\n- Vérifier la notarisation\n- Captures pour le site\n- Annoncer sur le forum\n\nIdée : montrer le dépôt dans la vidéo."
            : "v1.3 launch\n\n- Check notarization\n- Screenshots for the site\n- Post on the forum\n\nIdea: show the shelf in the video.")
        model.shelf.start(retentionHours: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notcher-demo-files-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = DemoArt.files(in: folder, french: french)
        model.shelf.add(files)
    }
}

/// What the camera shows besides the app: the caption, the pointer, a key being pressed.
@MainActor final class DemoDirector: ObservableObject {
    @Published var caption: String?
    @Published var pointer = CGPoint(x: 700, y: 330)
    @Published var pointerVisible = false
    @Published var pressed = false
    @Published var ripple = 0
    @Published var keycap: String?
    private var keyTask: Task<Void, Never>?
    func show(at point: CGPoint) { pointer = point; withAnimation(.easeOut(duration: 0.25)) { pointerVisible = true } }
    func hide() { withAnimation(.easeOut(duration: 0.3)) { pointerVisible = false } }
    func move(to point: CGPoint, duration: Double) async {
        withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: duration)) { pointer = point }
        try? await Task.sleep(for: .seconds(duration + 0.05))
    }
    func click() {
        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
        ripple += 1
        Task { try? await Task.sleep(for: .milliseconds(130)); withAnimation(.easeOut(duration: 0.12)) { self.pressed = false } }
    }
    func key(_ value: String) {
        keyTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { keycap = value }
        keyTask = Task { try? await Task.sleep(for: .seconds(1.1)); guard !Task.isCancelled else { return }; withAnimation(.easeOut(duration: 0.25)) { self.keycap = nil } }
    }
}

private struct DemoScene: View {
    @ObservedObject var model: AppModel
    @ObservedObject var director: DemoDirector
    var overlays = true
    private var french: Bool { Bundle.main.preferredLocalizations.first == "fr" }
    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            NotchView(model: model)
                .animation(.spring(response: 0.48, dampingFraction: 0.8), value: model.targetSize)
            if overlays { caption; pointer }
        }
        .frame(width: DemoRecorder.scene.width, height: DemoRecorder.scene.height)
        .clipped()
    }
    /// Drawn once: blurs are not captured by cacheDisplay, and redrawing them every frame was the bottleneck.
    private static let backdrop: NSImage = DemoArt.wallpaper(size: DemoRecorder.scene)
    private var wallpaper: some View { Image(nsImage: Self.backdrop).resizable() }
    private var menuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14))
            Text(verbatim: "Finder").fontWeight(.semibold)
            ForEach(french ? ["Fichier", "Édition", "Présentation", "Aller"] : ["File", "Edit", "View", "Go"], id: \.self) { Text(verbatim: $0) }
            Spacer()
            Image(systemName: "wifi"); Image(systemName: "battery.75percent"); Image(systemName: "magnifyingglass")
            Text(Date(), format: .dateTime.weekday(.abbreviated).hour().minute())
        }
        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16).frame(height: model.notchHeight)
        .background(.black.opacity(0.22))
    }
    private var caption: some View {
        VStack {
            Spacer()
            if let text = director.caption {
                Text(verbatim: text)
                    .font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.black.opacity(0.38), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    .id(text)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
        }.padding(.bottom, 22)
    }
    private var pointer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ZStack(alignment: .topLeading) {
                Circle().stroke(.white.opacity(0.7), lineWidth: 2).frame(width: 34, height: 34).offset(x: -17, y: -17)
                    .modifier(Ripple(trigger: director.ripple))
                Image(nsImage: NSCursor.arrow.image).resizable().interpolation(.high)
                    .frame(width: NSCursor.arrow.image.size.width * 1.15, height: NSCursor.arrow.image.size.height * 1.15)
                    .offset(x: -NSCursor.arrow.hotSpot.x * 1.15, y: -NSCursor.arrow.hotSpot.y * 1.15)
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

/// Covers and files drawn on the spot, so the demo shows no one's real content.
@MainActor enum DemoArt {
    /// Night-blue desktop with soft coloured light, blurred with Core Image at twice the scene's size.
    static func wallpaper(size: CGSize) -> NSImage {
        let pixels = CGSize(width: size.width * 2, height: size.height * 2)
        let sharp = NSImage(size: pixels, flipped: true) { rect in
            NSGradient(colors: [NSColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1), NSColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1)])?.draw(in: rect, angle: -90)
            let lights: [(NSColor, CGFloat, CGFloat, CGFloat)] = [
                (NSColor(red: 0.36, green: 0.55, blue: 0.95, alpha: 0.55), 0.16, 0.80, 0.62),
                (NSColor(red: 0.62, green: 0.40, blue: 0.95, alpha: 0.45), 0.88, 0.92, 0.55),
                (NSColor(red: 0.55, green: 0.88, blue: 0.62, alpha: 0.28), 0.52, 1.10, 0.45)
            ]
            for (color, x, y, radius) in lights {
                color.setFill()
                let r = radius * rect.height
                NSBezierPath(ovalIn: NSRect(x: x * rect.width - r, y: y * rect.height - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        guard let tiff = sharp.tiffRepresentation, let input = CIImage(data: tiff),
              let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 170])?.outputImage?.cropped(to: input.extent),
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
    static func files(in folder: URL, french: Bool) -> [URL] {
        var urls: [URL] = []
        func write(_ name: String, _ data: Data?) { guard let data else { return }; let url = folder.appendingPathComponent(name); try? data.write(to: url); urls.append(url) }
        write(french ? "Planche.png" : "Moodboard.png", picture([.systemPink, .systemOrange, .systemYellow], size: NSSize(width: 1200, height: 900)) { rect in
            for index in 0..<3 {
                NSColor(white: 1, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 80 + CGFloat(index) * 360, y: 220, width: 320, height: 460), xRadius: 30, yRadius: 30).fill()
            }
        })
        write(french ? "Maquette.png" : "Mockup.png", picture([.systemIndigo, .systemTeal], size: NSSize(width: 1400, height: 900)) { rect in
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
        write(french ? "Devis.pdf" : "Quote.pdf", pdf as Data)
        write(french ? "Notes de version.md" : "Release notes.md", Data((french ? "# Notcher 1.3\n\n- Miniatures dans le dépôt\n- Raccourci personnalisable\n" : "# Notcher 1.3\n\n- Shelf thumbnails\n- Custom shortcut\n").utf8))
        return urls
    }
}

/// H.264 encoder for frames captured from the window.
final class FrameWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var last = -1.0
    init(url: URL, width: Int, height: Int) throws {
        self.width = width; self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }
    @discardableResult func append(_ image: CGImage, seconds: Double) -> Bool {
        guard seconds > last, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return false }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else { return false }
        last = seconds
        return true
    }
    func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }
}

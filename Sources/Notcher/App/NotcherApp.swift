import AppKit
import SwiftUI
import Carbon
import NotcherCore
import UserNotifications

@main struct NotcherEntry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "--hardware" {
            // Also bound the child lifetime if the UI process is force-quit mid-request.
            alarm(4)
            defer { alarm(0) }
            do { try FileHandle.standardOutput.write(contentsOf: HardwareProbe.run(Array(args.dropFirst(2)))) }
            catch { exit(1) }
            return
        }
        if args.contains("--claude-statusline") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard data.count <= 2_000_000 else { return }
                let clean = try UsageParser.sanitizedClaudeSnapshot(data)
                try AppPaths.prepare()
                let file = AppPaths.integrations.appendingPathComponent("claude.json")
                try clean.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                if !args.contains("--quiet") {
                    let usage = try UsageParser.claude(clean)
                    let labels = usage.windows.map { "\($0.title) : \(Int($0.usedPercent)) %" }
                    print(([usage.model ?? "Claude Code"] + labels).joined(separator: " · "))
                }
            } catch { /* Status-line failures must not interrupt a Claude session. */ }
            return
        }
        if args.contains("--claude-event") {
            // Called by Claude Code's hooks: pass the event to the running app and leave at once.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if data.count <= 2_000_000, let event = ClaudeEvent.parse(data) { ClaudeRelay.post(event) }
            return
        }
        do { try AppPaths.prepare() }
        catch { fputs("Notcher : \(error.localizedDescription)\n", stderr); return }
        let preview = args.contains("--preview") || args.contains("--render-previews") || args.contains("--record-demo")
        // Two instances would stack two panels on the notch and write the same files.
        if !preview, let identifier = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.isFinishedLaunching && !$0.isTerminated }
            if let running {
                // A copy started to replace a crashed or frozen one waits for it to be gone.
                guard args.contains("--relaunched") else { running.activate(); return }
                for _ in 0..<32 where !running.isTerminated { usleep(250_000) }
                guard running.isTerminated else { return }
            }
        }
        if !preview { Resilience.install() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(preview ? .regular : .accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var toggleItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        model.openSettings = { [weak self] in self?.showSettings() }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--record-demo") {
            DemoRecorder.run(output: args.indices.contains(index + 1) ? args[index + 1] : "demo.mp4")
            return
        }
        if args.contains("--preview") || args.contains("--render-previews") {
            showPreview(render: args.contains("--render-previews"))
            return
        }
        controller = NotchController(model: model)
        model.openPanel = { [weak self] in self?.controller?.toggle() }
        model.onHotKeyChange = { [weak self] combo, suspended in self?.registerHotKey(combo, suspended: suspended) }
        model.start()
        controller?.show()
        buildMenu(); registerHotKey()
        if !model.preferences.defaults.bool(forKey: "hasLaunched") {
            model.preferences.defaults.set(true, forKey: "hasLaunched")
            model.expand()
        }
    }
    /// Copies removed from the shelf in the last few seconds are deleted before the app goes, or they would
    /// come back at the next launch. Bounded: a stuck disk never keeps Notcher from quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.shelf.hasUnfinishedRemovals else { return .terminateNow }
        let shelf = model.shelf
        Task { @MainActor in
            // Whichever ends first: the deletions, or three seconds.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shelf.finishRemovals() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop(); controller?.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
    /// Opening the app again from the Finder shows the panel instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.open(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { CommandLine.arguments.contains("--preview") }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notcher")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: L("Ouvrir Notcher"), action: #selector(toggleNotch), keyEquivalent: " ")
        toggle.target = self; menu.addItem(toggle); toggleItem = toggle
        updateMenuShortcut(model.preferences.hotKey)
        let settings = NSMenuItem(title: L("Réglages…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let about = NSMenuItem(title: "Notcher \(version)", action: nil, keyEquivalent: ""); about.isEnabled = false
        menu.addItem(about)
        let quit = NSMenuItem(title: L("Quitter Notcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); item.menu = menu; statusItem = item
    }
    @objc private func toggleNotch() { controller?.toggle() }
    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("Réglages de Notcher"); window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.backgroundColor = NSColor(white: 0.055, alpha: 1); window.isMovableByWindowBackground = false // Dragging a widget must never drag the window.
        window.contentView = NSHostingView(rootView: SettingsView(model: model).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Registers the chosen shortcut, replacing the previous one. Suspended while the settings record a new one,
    /// so pressing the current combination reaches the recorder instead of toggling the panel.
    private func registerHotKey(_ requested: HotKeyCombo? = nil, suspended: Bool = false) {
        let combo = requested ?? model.preferences.hotKey
        if hotKeyHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { delegate.toggleNotch() }
                return noErr
            }, 1, &event, context, &hotKeyHandler)
        }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        updateMenuShortcut(combo)
        guard !suspended else { return }
        let id = EventHotKeyID(signature: 0x4E544348, id: 1)
        let result = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if result == noErr { model.hotKeyProblem = nil; return }
        hotKey = nil
        let problem = L("%@ est déjà utilisé par une autre app. Choisis un autre raccourci dans Réglages → Comportement.", combo.display)
        // Said once in the panel, the next time it opens, and kept in the settings until it is solved.
        if model.hotKeyProblem != problem { model.notifyWhenOpen(problem) }
        model.hotKeyProblem = problem
    }
    /// The menu shows the shortcut actually in use.
    private func updateMenuShortcut(_ combo: HotKeyCombo) {
        guard let toggleItem else { return }
        toggleItem.keyEquivalent = combo.keyEquivalent
        var mask: NSEvent.ModifierFlags = []
        if combo.command { mask.insert(.command) }
        if combo.option { mask.insert(.option) }
        if combo.control { mask.insert(.control) }
        if combo.shift { mask.insert(.shift) }
        toggleItem.keyEquivalentModifierMask = mask
    }
    private func showPreview(render: Bool) {
        model.expanded = true; model.presentationExpanded = true; model.pinned = true
        Haptics.enabled = false
        model.shelf.start(retentionHours: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Notcher — aperçu de développement"
        let view = NSHostingView(rootView: ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.14, green: 0.20, blue: 0.23), Color(red: 0.05, green: 0.08, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            NotchView(model: model).padding(.top, 36)
        }.frame(width: 850, height: 600).preferredColorScheme(.dark))
        window.contentView = view; window.center(); window.makeKeyAndOrderFront(nil); previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        guard render else { return }
        Task { @MainActor in
            let output = AppPaths.support.appendingPathComponent("Previews")
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for tab in NotchTab.allCases {
                model.tab = tab
                try? await Task.sleep(for: .milliseconds(600))
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent("\(tab.id).png")) }
                }
            }
            for pane in SettingsView.Pane.allCases {
                let settings = NSHostingView(rootView: SettingsView(model: model, pane: pane).preferredColorScheme(.dark))
                let frame = NSRect(origin: .zero, size: SettingsView.size)
                let holder = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                holder.contentView = settings; holder.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(500))
                settings.layoutSubtreeIfNeeded()
                if let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
                    settings.cacheDisplay(in: settings.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent("Réglages-\(pane.id).png")) }
                }
                holder.orderOut(nil)
            }
            NSApp.terminate(nil)
        }
    }
}

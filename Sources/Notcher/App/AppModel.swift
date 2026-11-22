import AppKit
import Combine
import SwiftUI
import NotcherCore

enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Aperçu", files = "Dépôt", notes = "Texte", agents = "Agents", tools = "Outils"
    var id: String { rawValue }
    /// Stored in preferences; independent of the displayed name.
    var key: String {
        switch self {
        case .home: return "home"
        case .files: return "files"
        case .notes: return "notes"
        case .agents: return "agents"
        case .tools: return "tools"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .files: return "tray"
        case .notes: return "text.alignleft"
        case .agents: return "sparkles"
        case .tools: return "slider.horizontal.3"
        }
    }
}
/// Trackpad feedback. Silent on hardware without a Force Touch trackpad.
@MainActor enum Haptics {
    static var enabled = true
    static func play(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
struct NotchActivity: Equatable {
    var symbol: String
    var title: String
    var value: Double?
    var color: Color?
    /// Picture shown instead of the symbol (the connected headphones, for instance).
    var artwork: NSImage? = nil
    /// Short text for the right wing when there is no gauge.
    var trailing: String? = nil
    /// Extra line under the notch; the closed panel grows to hold it.
    var details: [String] = []
    /// Symbol for the right wing of an event told with pictures only (no title).
    var mark: String? = nil
    var markColor: Color? = nil
    var pictureOnly: Bool { title.isEmpty }
}
struct VolumeReadout: Equatable {
    var level: Double
    var muted: Bool
}
/// A quick change (a key pressed) told in a strip added to the right of whatever the closed notch shows,
/// rather than in place of it.
enum MinorAlert: Equatable {
    case volume(VolumeReadout), brightness(Double), capsLock(Bool)
    var level: Double? {
        switch self {
        case .volume(let value): return value.muted ? 0 : value.level
        case .brightness(let value): return value
        case .capsLock: return nil
        }
    }
}
struct ToastAction {
    let title: String
    let run: () -> Void
}
/// A state shown in the closed notch for as long as it lasts: Claude answering, a meeting coming up…
struct NotchAmbient: Equatable {
    enum Motion { case none, breathing, pulsing }
    var symbol: String
    var artwork: NSImage? = nil
    var color: Color? = nil
    /// Right wing: a short text, or a symbol when there is nothing to count.
    var trailing: String? = nil
    var mark: String? = nil
    var motion = Motion.none
}

@MainActor final class AppModel: ObservableObject {
    let preferences: Preferences
    /// The demo recording passes preferences of its own, so it never reads or writes the user's.
    init(preferences: Preferences) { self.preferences = preferences }
    convenience init() { self.init(preferences: Preferences()) }
    let media = MediaService()
    let system = SystemService()
    let shelf = ShelfService()
    let notes = NotesService()
    let focus = FocusService()
    let calendar = CalendarService()
    let camera = CameraService()
    let shortcuts = ShortcutsService()
    let bluetooth = BluetoothService()
    let updates = UpdateService()
    let downloads = DownloadWatcher()
    let capsLock = CapsLockWatcher()
    let network = NetworkWatcher()
    let screenshots = ScreenshotWatcher()
    private lazy var brightnessWatcher = BrightnessWatcher { level in Task { @MainActor [weak self] in self?.announceBrightness(level) } }
    private lazy var captureWatcher = CaptureWatcher { old, new in Task { @MainActor [weak self] in self?.announceCapture(old, new) } }
    private var batteryWatch = BatteryWatch()
    /// Events already announced as starting, so a meeting is announced once.
    private var announcedEvents: [String: Date] = [:]
    lazy var agents = AgentService(preferences: preferences)
    let usageStats = UsageStatsService()
    lazy var clipboard = ClipboardService(preferences: preferences)
    @Published var expanded = false
    @Published var presentationExpanded = false
    /// Size currently drawn; animated by the controller towards `targetSize`.
    @Published var shapeSize = CGSize(width: 334, height: 32)
    @Published var pinned = false
    @Published var tab: NotchTab = .home
    @Published var toolTab: ToolTab = .focus
    @Published var activity: NotchActivity?
    @Published private(set) var ambient: NotchAmbient?
    private var ambientTimer: Timer?
    @Published var toast: String?
    /// A button inside the toast, such as "Annuler" after a removal.
    @Published private(set) var toastAction: ToastAction?
    /// A message raised while the panel was closed, shown the next time it opens.
    private var deferredNotice: String?
    /// Why the global shortcut does not work, shown in the settings; nil when it is registered.
    @Published var hotKeyProblem: String?
    /// Set by the app delegate: registers this shortcut, or none while the settings record a new one.
    var onHotKeyChange: ((_ combo: HotKeyCombo, _ suspended: Bool) -> Void)?
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    @Published var dragging = false
    /// One token per system window opened from the panel (open and save panels, Quick Look, a confirmation).
    /// Each closes only its own, so a window that closes cannot release the panel held by another.
    @Published private(set) var openDialogs: Set<UUID> = []
    var dialogOpen: Bool { !openDialogs.isEmpty }
    func beginDialog() -> UUID { let token = UUID(); openDialogs.insert(token); return token }
    func endDialog(_ token: UUID) { openDialogs.remove(token) }
    func endAllDialogs() { if !openDialogs.isEmpty { openDialogs = [] } }
    /// Pointer resting on the closed notch in "hover then click" mode.
    @Published var hovering = false
    /// Pointer resting on the bars of the closed notch: they turn into a play/pause button.
    @Published var playbackHover = false
    /// The closed notch shows the cover and the bars, and nothing else is using its right wing.
    var compactPlaybackVisible: Bool {
        !expanded && activity == nil && ambient == nil && focus.clock.deadline == nil && media.compactTrack != nil
    }
    /// Volume, brightness or Caps Lock just changed: the right wing grows to hold it, beside what is already shown.
    @Published private(set) var minor: MinorAlert?
    private var minorTask: Task<Void, Never>?
    var minorVisible: Bool { minor != nil && !expanded && !permissionCardVisible }
    /// With music the cover and the bars already say what the level is about; elsewhere a small symbol does.
    var minorShowsSymbol: Bool {
        guard let minor else { return false }
        if case .volume = minor { return !compactPlaybackVisible }
        return true
    }
    /// Room the strip takes: the figure and its bar, or the symbol alone, plus the flare of the shape.
    var minorWidth: CGFloat {
        guard minorVisible, let minor else { return 0 }
        let content: CGFloat = minor.level == nil ? 14 : (minorShowsSymbol ? 12 + 8 : 0) + 18 + 8 + 34
        return 8 + content + NotchHeader.ear + 4
    }
    /// A titled event: its picture on the left, its words on the right. The right wing is cut to fit them
    /// instead of mirroring the left one.
    var activityExtra: CGFloat {
        guard !expanded, let activity, !activity.pictureOnly else { return 0 }
        return max(0, Self.rightWing(for: activity) - CompactPanel.size(notchWidth: 0, notchHeight: 0, media: false, focus: false, activity: false, ambient: true).width / 2)
    }
    static let activityTitleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let activityTitleLimit: CGFloat = 170
    static func rightWing(for activity: NotchActivity) -> CGFloat {
        let title = min(activityTitleLimit, ceil((L(activity.title) as NSString).size(withAttributes: [.font: activityTitleFont]).width))
        var end: CGFloat = 0
        if activity.value != nil { end = 8 + 44 + 8 + 24 }
        else if let trailing = activity.trailing { end = 8 + 16 + 8 + ceil((trailing as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]).width) }
        else if activity.mark != nil { end = 8 + 18 }
        return 10 + title + end + NotchHeader.ear + 14
    }
    /// How far the closed shape sits to the right of the notch's centre: only its right wing grows.
    var targetShift: CGFloat { (activityExtra + minorWidth) / 2 }
    /// Shift currently drawn; animated by the controller together with `shapeSize`.
    @Published var shapeShift: CGFloat = 0
    func showMinor(_ value: MinorAlert, seconds: Double = 1.6) {
        minorTask?.cancel(); minor = value
        minorTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(seconds)); self?.minor = nil } catch {} }
    }
    private var lastPlaybackToggle = Date.distantPast
    /// A click on the bars. One press can reach the app by two routes; only the first one counts.
    func togglePlaybackFromNotch() {
        guard compactPlaybackVisible, Date().timeIntervalSince(lastPlaybackToggle) > 0.25 else { return }
        lastPlaybackToggle = Date()
        media.command("toggle"); Haptics.play(.levelChange)
    }
    var onGeometryChange: (() -> Void)?
    var openSettings: (() -> Void)?
    var openPanel: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var activityTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var cleanupTimer: Timer?
    var expandedWidth: CGFloat { preferences.panelSize.width }
    var pageHeight: CGFloat { preferences.panelSize.pageHeight }
    var collapsedSize: CGSize {
        CompactPanel.size(notchWidth: notchWidth, notchHeight: notchHeight, media: media.compactTrack != nil, focus: focus.clock.deadline != nil,
                          activity: false, idleInfo: preferences.compactStyle == .info, ambient: ambient != nil || activity != nil, hovered: hovering)
    }
    var targetSize: CGSize { CGSize(width: width, height: height) }
    /// Height of the strip under the closed notch that holds an activity's details.
    static let detailHeight: CGFloat = 26
    var visibleTabs: [NotchTab] { NotchTab.allCases.filter { $0 == .home || (!preferences.hiddenTabs.contains($0.key) && ($0 != .agents || preferences.developerMode)) } }
    var collapsedWidth: CGFloat { collapsedSize.width }
    var width: CGFloat { expanded ? expandedWidth : max(collapsedWidth + activityExtra + minorWidth, permissionCardVisible ? Self.permissionCard.width : 0) }
    var height: CGFloat {
        if expanded { return notchHeight + pageHeight + 84 }
        return collapsedSize.height + (activity?.details.isEmpty == false ? Self.detailHeight : 0) + (permissionCardVisible ? Self.permissionCard.height : 0)
    }
    /// The question Claude Code is waiting on; the closed notch grows a card under it to answer.
    var permission: PendingPermission? { preferences.developerMode ? agents.permissionRequests.first : nil }
    var permissionCardVisible: Bool { !expanded && permission != nil }
    static let permissionCard = CGSize(width: 460, height: 140)

    func start() {
        agents.onLimit = { [weak self] title in guard self?.preferences.developerMode == true else { return }; self?.showActivity(.init(symbol: "sparkles", title: title, color: .orange), seconds: 6) }
        system.onVolumeChange = { [weak self] volume, muted in
            guard let self, self.preferences.allows(.volume), !self.expanded else { return }
            self.showMinor(.volume(VolumeReadout(level: muted ? 0 : volume, muted: muted)))
        }
        system.onPowerChange = { [weak self] charging in
            guard let self, self.preferences.allows(.power) else { return }
            let level = self.system.battery.map { Double($0) / 100 }
            self.showActivity(.init(symbol: charging ? "bolt.fill" : "battery.75percent", title: charging ? "En charge" : "Sur batterie", value: level), seconds: 3)
        }
        agents.onClaudeFinished = { [weak self] in
            guard let self, self.preferences.allows(.claudeDone) else { return }
            self.showActivity(.init(symbol: "asterisk", title: "", color: Theme.orange, artwork: ClaudeMark.icon, mark: "checkmark.circle.fill", markColor: Theme.green), seconds: 3.5)
            Haptics.play(.levelChange)
        }
        downloads.onFinished = { [weak self] path in
            guard let self, self.preferences.allows(.download) else { return }
            self.showActivity(.init(symbol: "doc.fill", title: "", artwork: DownloadWatcher.icon(for: path), mark: "arrow.down.circle.fill"), seconds: 3.5)
        }
        system.onHeadphones = { [weak self] name in self?.announceHeadphones(name) }
        system.onHeadphonesGone = { [weak self] name in
            guard let self, self.preferences.allows(.headphones) else { return }
            self.showActivity(.init(symbol: Accessory.symbol(productID: nil, name: name), title: name, color: .secondary, artwork: Accessory.image(productID: nil, name: name),
                                    mark: "xmark.circle.fill", markColor: .secondary), seconds: 2.5)
        }
        system.onBattery = { [weak self] level, charging in self?.announceBattery(level, charging: charging) }
        system.onBrightnessSet = { [weak self] in self?.brightnessWatcher.ignoreFor(1.5) }
        system.onAwakeEnded = { [weak self] in
            guard let self, self.preferences.allows(.awake) else { return }
            self.showActivity(.init(symbol: "cup.and.saucer", title: "Veille de nouveau permise"), seconds: 4)
        }
        capsLock.onChange = { [weak self] on in
            guard let self, self.preferences.allows(.capsLock) else { return }
            self.showMinor(.capsLock(on), seconds: 1.4)
        }
        network.onChange = { [weak self] online in
            guard let self, self.preferences.allows(.network) else { return }
            self.showActivity(online ? .init(symbol: "wifi", title: "De nouveau en ligne", color: Theme.green)
                                     : .init(symbol: "wifi.slash", title: "Hors ligne", color: .red), seconds: online ? 2.5 : 4)
            if !online { Haptics.play(.generic) }
        }
        screenshots.onCapture = { [weak self] path in
            guard let self, self.preferences.allows(.screenshot) else { return }
            let video = ["mov", "mp4"].contains((path as NSString).pathExtension.lowercased())
            self.showActivity(.init(symbol: video ? "record.circle" : "camera.viewfinder", title: video ? "Enregistrement sauvegardé" : "Capture enregistrée"), seconds: 2.5)
        }
        screenshots.onCopied = { [weak self] in
            guard let self, self.preferences.allows(.screenshot) else { return }
            self.showActivity(.init(symbol: "camera.viewfinder", title: "Capture copiée"), seconds: 2.5)
        }
        agents.onClaudeIdle = { [weak self] in
            guard let self, self.preferences.allows(.claudeIdle) else { return }
            self.showActivity(.init(symbol: "asterisk", title: "", color: Theme.orange, artwork: ClaudeMark.icon, mark: "bubble.left.fill", markColor: Theme.orange), seconds: 4)
        }
        agents.onShip = { [weak self] action, failed in
            guard let self, self.preferences.allows(.claudeShipped) else { return }
            self.showActivity(.init(symbol: "asterisk", title: failed ? action.failure : action.title, color: Theme.orange, artwork: ClaudeMark.icon,
                                    mark: failed ? "xmark.octagon.fill" : action.symbol, markColor: failed ? .red : Theme.green), seconds: 3.5)
            Haptics.play(failed ? .generic : .levelChange)
        }
        preferences.$mediaRestMinutes.sink { [weak self] value in self?.media.restMinutes = value }.store(in: &subscriptions)
        media.$resting.dropFirst().removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        $hovering.dropFirst().removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        focus.onFinished = { [weak self] in guard self?.preferences.allows(.timer) == true else { return }; self?.showActivity(.init(symbol: "checkmark.circle.fill", title: "Pomodoro terminé"), seconds: 10) }
        shelf.onAdded = { [weak self] count in self?.notify(L(count > 1 ? "%lld éléments ajoutés au dépôt" : "%lld élément ajouté au dépôt", count)) }
        // @Published sends before the property changes: register the value received, not the property.
        preferences.$hotKey.dropFirst().removeDuplicates().sink { [weak self] combo in self?.onHotKeyChange?(combo, false) }.store(in: &subscriptions)
        preferences.$haptics.sink { value in MainActor.assumeIsolated { Haptics.enabled = value } }.store(in: &subscriptions)
        preferences.$compactStyle.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        preferences.$hiddenTabs.sink { [weak self] hidden in
            guard let self, self.tab != .home, hidden.contains(self.tab.key) else { return }
            self.tab = .home
        }.store(in: &subscriptions)
        preferences.$mediaEnabled.sink { [weak self] value in self?.media.setEnabled(value) }.store(in: &subscriptions)
        agents.onPermissionRequest = { Haptics.play(.levelChange) }
        // The card under the closed notch follows the list of open questions.
        agents.$permissionRequests.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send(); self?.onGeometryChange?()
        }.store(in: &subscriptions)
        preferences.$agentApprovals.dropFirst().sink { [weak self] value in if !value { self?.agents.releasePermissions() } }.store(in: &subscriptions)
        preferences.$developerMode.dropFirst().removeDuplicates().sink { [weak self] value in
            guard let self, !value else { return }
            self.agents.silence()
            if self.tab == .agents { self.tab = .home }
            // The quotas widget leaves the overview with the mode that gives it something to show.
            var layout = self.preferences.homeLayout
            if layout.remove(.agents) { self.preferences.homeLayout = layout }
        }.store(in: &subscriptions)
        preferences.$screenID.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        preferences.$panelSize.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.$retentionHours.dropFirst().sink { [weak self] value in self?.shelf.purge(hours: value) }.store(in: &subscriptions)
        preferences.$clipboardEnabled.dropFirst().sink { [weak self] value in if !value { self?.clipboard.clear() } }.store(in: &subscriptions)
        $expanded.dropFirst().removeDuplicates().sink { [weak self] value in
            if !value { self?.camera.stop(); self?.bluetooth.cancel(); self?.shelf.selection = [] }
            self?.media.attentive = value
            self?.onGeometryChange?()
        }.store(in: &subscriptions)
        $activity.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        // Only a change of kind changes the room it takes; a new level is drawn in place.
        $minor.map { value -> Int in switch value { case nil: return 0; case .volume: return 1; case .brightness: return 2; case .capsLock: return 3 } }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        media.$track.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        focus.$clock.map { $0.deadline != nil }.removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        // Published values change after their publisher fires: the state is recomputed on the next turn of the run loop.
        let sources: [AnyPublisher<Void, Never>] = [
            agents.$claudeWorking.map { _ in }.eraseToAnyPublisher(), agents.$claudeWaiting.map { _ in }.eraseToAnyPublisher(),
            agents.$claude.map { _ in }.eraseToAnyPublisher(), agents.$claudePromptAt.map { _ in }.eraseToAnyPublisher(), media.$track.map { _ in }.eraseToAnyPublisher(),
            media.$resting.map { _ in }.eraseToAnyPublisher(), focus.$clock.map { _ in }.eraseToAnyPublisher(),
            calendar.$events.map { _ in }.eraseToAnyPublisher(), system.$battery.map { _ in }.eraseToAnyPublisher(),
            system.$charging.map { _ in }.eraseToAnyPublisher(), system.$awake.map { _ in }.eraseToAnyPublisher(),
            preferences.$showHUD.map { _ in }.eraseToAnyPublisher(), preferences.$developerMode.map { _ in }.eraseToAnyPublisher(), preferences.$compactStyle.map { _ in }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(sources).receive(on: RunLoop.main).sink { [weak self] in self?.refreshAmbient() }.store(in: &subscriptions)
        agents.$claudePromptAt.sink { [weak self] _ in
            Task { try? await Task.sleep(for: .seconds(Self.claudeAnswerDisplay + 0.05)); self?.refreshAmbient() }
        }.store(in: &subscriptions)
        $ambient.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        // Countdowns (minutes before a meeting, awake time left) move without any publisher firing.
        ambientTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshAmbient(); self?.announceStartingEvent() } }
        ambientTimer?.tolerance = 5
        shelf.start(retentionHours: preferences.retentionHours)
        media.start(); system.start(); agents.start(); focus.start(); calendar.start(); clipboard.start(); updates.start(); downloads.start()
        capsLock.start(); network.start(); screenshots.start(); brightnessWatcher.start(); captureWatcher.start()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.shelf.purge(hours: self.preferences.retentionHours) } }
    }
    func stop() {
        notes.save(); media.stop(); system.stop(); agents.stop(); focus.stop(); calendar.stop(); camera.stop(); clipboard.stop(); bluetooth.cancel(); updates.stop(); downloads.stop()
        capsLock.stop(); network.stop(); screenshots.stop(); brightnessWatcher.stop(); captureWatcher.stop(); cleanupTimer?.invalidate(); ambientTimer?.invalidate()
    }
    func expand(tab: NotchTab? = nil) {
        if let tab { self.tab = tab } // A drop may reveal a tab hidden from the navigation.
        guard !expanded else { return }
        hovering = false
        expanded = true
        Haptics.play(.levelChange)
        if let notice = deferredNotice { deferredNotice = nil; notify(notice) }
    }
    func collapse() {
        guard !dialogOpen, expanded else { return }
        expanded = false; pinned = false
        Haptics.play(.alignment)
    }
    func select(_ value: NotchTab) {
        guard tab != value, visibleTabs.contains(value) else { return }
        tab = value
        if value != .tools { camera.stop() }
        Haptics.play(.alignment)
    }
    func sendSelectedNoteToNotes() {
        notes.sendToNotes { [weak self] failure in self?.notify(failure ?? "Envoyé vers Notes") }
    }
    /// Headphones that just connected appear in the notch at once; their battery follows when macOS knows it.
    private func announceHeadphones(_ name: String) {
        guard preferences.allows(.headphones) else { return }
        var card = NotchActivity(symbol: Accessory.symbol(productID: nil, name: name), title: name, artwork: Accessory.image(productID: nil, name: name))
        showActivity(card, seconds: 5)
        Task { [weak self] in
            for attempt in 0..<3 {
                if attempt > 0 { do { try await Task.sleep(for: .seconds(2)) } catch { return } }
                guard let self, self.activity?.title == name else { return }
                guard let info = await Accessory.lookup(name: name) else { continue }
                card.symbol = Accessory.symbol(productID: info.productID, name: name)
                card.artwork = Accessory.image(productID: info.productID, name: name) ?? card.artwork
                card.trailing = info.summary.map { "\($0) %" }
                card.details = info.details
                guard self.activity?.title == name else { return }
                self.showActivity(card, seconds: 5)
                if info.summary != nil { return }
            }
        }
    }
    private func announceBrightness(_ level: Double) {
        guard preferences.allows(.brightness), !expanded else { return }
        system.brightness = level
        showMinor(.brightness(level))
    }
    private func announceBattery(_ level: Int, charging: Bool) {
        guard let event = batteryWatch.update(level: level, charging: charging), preferences.allows(.battery) else { return }
        switch event {
        case .full: showActivity(.init(symbol: "battery.100percent.bolt", title: "Batterie chargée", value: 1, color: Theme.green), seconds: 4)
        case .low(let value):
            showActivity(.init(symbol: value <= 10 ? "battery.0percent" : "battery.25percent", title: value <= 10 ? "Batterie très faible" : "Batterie faible",
                               value: Double(value) / 100, color: .red), seconds: 6)
            Haptics.play(.generic)
        }
    }
    /// A microphone or a camera starts being used by another app.
    private func announceCapture(_ old: CaptureWatcher.State, _ new: CaptureWatcher.State) {
        if new.camera && !old.camera && !camera.active && preferences.allows(.camera) {
            let app = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
            showActivity(.init(symbol: "video.fill", title: app?.localizedName ?? "Caméra allumée", color: Theme.green, artwork: app?.icon, mark: "video.fill", markColor: Theme.green), seconds: 3)
            return
        }
        guard preferences.allows(.microphone), let pid = new.microphone.first(where: { !old.microphone.contains($0) }) else { return }
        // System listeners (Siri, dictation) belong to no app and are not announced.
        guard let app = CaptureWatcher.app(for: pid) else { return }
        // Another process of an app already announced (a browser tab after another) is not news.
        let known = Set(old.microphone.compactMap { CaptureWatcher.app(for: $0)?.processIdentifier })
        if known.contains(app.processIdentifier) { return }
        showActivity(.init(symbol: "mic.fill", title: app.localizedName ?? "Micro utilisé", color: Theme.orange, artwork: app.icon, mark: "mic.fill", markColor: Theme.orange), seconds: 3)
    }
    /// A meeting starts: once, within its first minute.
    private func announceStartingEvent(now: Date = Date()) {
        guard preferences.allows(.calendar) else { return }
        announcedEvents = announcedEvents.filter { now.timeIntervalSince($0.value) < 3600 }
        func key(_ item: CalendarItem) -> String { item.id + "@\(item.start.timeIntervalSince1970)" }
        guard let event = calendar.events.first(where: { !$0.allDay && $0.start <= now && now.timeIntervalSince($0.start) < 60 && announcedEvents[key($0)] == nil }) else { return }
        announcedEvents[key(event)] = event.start
        showActivity(.init(symbol: event.meeting == nil ? "calendar" : "video.fill", title: event.title.isEmpty ? L("Rendez-vous") : event.title, color: Color(nsColor: event.color)), seconds: 8)
        Haptics.play(.levelChange)
    }
    /// How long the closed notch shows that Claude has started answering; the end of the answer is announced separately.
    static let claudeAnswerDisplay: TimeInterval = 5
    private func refreshAmbient() {
        let value = currentAmbient()
        if value != ambient { ambient = value }
    }
    /// The one lasting state worth showing, most pressing first. Nil leaves the notch bare, or to the
    /// timer and the player, which draw themselves.
    func currentAmbient(now: Date = Date()) -> NotchAmbient? {
        guard preferences.showHUD else { return nil }
        if preferences.developerMode, agents.claudeWaiting > 0 {
            return NotchAmbient(symbol: "asterisk", artwork: ClaudeMark.icon, color: Theme.orange, mark: "hand.raised.fill", motion: .pulsing)
        }
        // Discreet keeps the closed notch bare: only a request that blocks work is worth breaking the silence.
        if preferences.compactStyle == .minimal { return nil }
        if focus.clock.deadline != nil { return nil }
        if preferences.developerMode, agents.claudeWorking > 0, let asked = agents.claudePromptAt, now.timeIntervalSince(asked) < Self.claudeAnswerDisplay {
            let quota = agents.claude.flatMap { usage in usage.isStale(at: now) ? nil : usage.windows.first { $0.id == "five_hour" && !$0.isExpired(at: now) } }
            return NotchAmbient(symbol: "asterisk", artwork: ClaudeMark.icon, color: Theme.orange,
                                trailing: quota.map { "\(Int($0.usedPercent.rounded())) %" }, mark: "ellipsis", motion: .breathing)
        }
        if media.compactTrack != nil { return nil }
        let soon = calendar.events.filter { !$0.allDay && $0.start > now && $0.start.timeIntervalSince(now) <= 30 * 60 }.min { $0.start < $1.start }
        if let soon {
            return NotchAmbient(symbol: "calendar", color: Color(nsColor: soon.color), trailing: L("%lld min", Int((soon.start.timeIntervalSince(now) / 60).rounded(.up))))
        }
        if let level = system.battery, level <= 20, !system.charging {
            return NotchAmbient(symbol: "battery.25percent", color: .red, trailing: "\(level) %")
        }
        if system.awake {
            return NotchAmbient(symbol: "cup.and.saucer.fill", trailing: system.awakeRemaining.map { L("%lld min", Int(($0 / 60).rounded(.up))) })
        }
        return nil
    }
    func showActivity(_ value: NotchActivity, seconds: Double) {
        activityTask?.cancel(); activity = value
        activityTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(seconds)); self?.activity = nil } catch {} }
    }
    func notify(_ value: String, action: ToastAction? = nil) {
        toastTask?.cancel(); toast = value; toastAction = action
        let seconds = action == nil ? 3 : ShelfService.undoWindow
        toastTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(seconds)); self?.toast = nil; self?.toastAction = nil } catch {} }
    }
    /// Shown now if the panel is open, otherwise as soon as it opens: a toast on a closed panel is never seen.
    func notifyWhenOpen(_ value: String) {
        if expanded { notify(value) } else { deferredNotice = value }
    }
    func dismissToast() { toastTask?.cancel(); toast = nil; toastAction = nil }

    // MARK: Shelf

    /// Removes copies from the shelf, with a moment to take it back.
    func removeFromShelf(_ ids: Set<UUID>) {
        let count = shelf.remove(ids)
        guard count > 0 else { return }
        Haptics.play(.alignment)
        notify(L(count > 1 ? "%lld fichiers retirés" : "%lld fichier retiré", count), action: ToastAction(title: "Annuler le retrait") { [weak self] in self?.undoShelfRemoval() })
    }
    func undoShelfRemoval() {
        guard shelf.canUndo else { return }
        shelf.undoRemoval(); dismissToast(); Haptics.play(.levelChange)
    }
    /// Space bar on the shelf: shows the selection in Quick Look, or closes it.
    func toggleShelfPreview() {
        if FilePreview.shared.isVisible { FilePreview.shared.close(); return }
        let chosen = shelf.selected()
        let items = chosen.isEmpty ? Array(shelf.items.prefix(1)) : chosen
        guard !items.isEmpty else { return }
        preview(items.map(shelf.url(for:)))
    }
    func preview(_ urls: [URL]) {
        let token = beginDialog()
        FilePreview.shared.show(urls) { [weak self] in self?.endDialog(token) }
    }
    /// Keys of the shelf while its tab is shown. Returns true when the key was used.
    func handleShelfKey(keyCode: UInt16, characters: String?, command: Bool) -> Bool {
        guard tab == .files else { return false }
        switch (keyCode, command) {
        case (49, false): toggleShelfPreview(); return true
        case (51, _), (117, _):
            guard !shelf.selection.isEmpty else { return false }
            removeFromShelf(shelf.selection); return true
        case (_, true) where characters == "a":
            shelf.selection = Set(shelf.visible.map(\.id)); return true
        case (_, true) where characters == "z":
            guard shelf.canUndo else { return false }
            undoShelfRemoval(); return true
        case (53, false):
            guard !shelf.selection.isEmpty else { return false }
            shelf.selection = []; return true
        default: return false
        }
    }
}

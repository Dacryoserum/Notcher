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
    lazy var agents = AgentService(preferences: preferences)
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
    /// The volume just changed while the notch shows music: its right wing grows to hold the level.
    @Published private(set) var musicVolume: VolumeReadout?
    private var musicVolumeTask: Task<Void, Never>?
    static let volumeWing: CGFloat = 74
    var musicVolumeVisible: Bool { musicVolume != nil && compactPlaybackVisible && !permissionCardVisible }
    /// How far the closed shape sits to the right of the notch's centre: only its right wing grows for the volume.
    var targetShift: CGFloat { musicVolumeVisible ? Self.volumeWing / 2 : 0 }
    /// Shift currently drawn; animated by the controller together with `shapeSize`.
    @Published var shapeShift: CGFloat = 0
    private func showMusicVolume(_ value: VolumeReadout) {
        musicVolumeTask?.cancel(); musicVolume = value
        musicVolumeTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(1.6)); self?.musicVolume = nil } catch {} }
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
                          activity: activity.map { !$0.pictureOnly } ?? false, idleInfo: preferences.compactStyle == .info,
                          ambient: ambient != nil || activity?.pictureOnly == true, hovered: hovering)
    }
    var targetSize: CGSize { CGSize(width: width, height: height) }
    /// Height of the strip under the closed notch that holds an activity's details.
    static let detailHeight: CGFloat = 26
    var visibleTabs: [NotchTab] { NotchTab.allCases.filter { $0 == .home || (!preferences.hiddenTabs.contains($0.key) && ($0 != .agents || preferences.developerMode)) } }
    var collapsedWidth: CGFloat { collapsedSize.width }
    var width: CGFloat { expanded ? expandedWidth : max(collapsedWidth + (musicVolumeVisible ? Self.volumeWing : 0), permissionCardVisible ? Self.permissionCard.width : 0) }
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
            guard let self, self.preferences.showHUD else { return }
            // Turning the volume while music plays is about the music: the level joins the cover and the bars.
            if self.compactPlaybackVisible && !self.permissionCardVisible { self.showMusicVolume(VolumeReadout(level: muted ? 0 : volume, muted: muted)); return }
            let symbol = muted || volume <= 0 ? "speaker.slash.fill" : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            self.showActivity(.init(symbol: symbol, title: muted ? "Silence" : "Volume", value: muted ? 0 : volume), seconds: 1.6)
        }
        system.onPowerChange = { [weak self] charging in
            guard let self, self.preferences.showHUD else { return }
            let level = self.system.battery.map { Double($0) / 100 }
            self.showActivity(.init(symbol: charging ? "bolt.fill" : "battery.75percent", title: charging ? "En charge" : "Sur batterie", value: level), seconds: 3)
        }
        agents.onClaudeFinished = { [weak self] in
            guard let self, self.preferences.showHUD, self.preferences.developerMode else { return }
            self.showActivity(.init(symbol: "asterisk", title: "", color: Theme.orange, artwork: ClaudeMark.icon, mark: "checkmark.circle.fill", markColor: Theme.green), seconds: 3.5)
            Haptics.play(.levelChange)
        }
        downloads.onFinished = { [weak self] path in
            guard let self, self.preferences.showHUD else { return }
            self.showActivity(.init(symbol: "doc.fill", title: "", artwork: DownloadWatcher.icon(for: path), mark: "arrow.down.circle.fill"), seconds: 3.5)
        }
        system.onHeadphones = { [weak self] name in self?.announceHeadphones(name) }
        preferences.$mediaRestMinutes.sink { [weak self] value in self?.media.restMinutes = value }.store(in: &subscriptions)
        media.$resting.dropFirst().removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        $hovering.dropFirst().removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        focus.onFinished = { [weak self] in self?.showActivity(.init(symbol: "checkmark.circle.fill", title: "Pomodoro terminé"), seconds: 10) }
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
        $musicVolume.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
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
        ambientTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshAmbient() } }
        ambientTimer?.tolerance = 5
        shelf.start(retentionHours: preferences.retentionHours)
        media.start(); system.start(); agents.start(); focus.start(); calendar.start(); clipboard.start(); updates.start(); downloads.start()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.shelf.purge(hours: self.preferences.retentionHours) } }
    }
    func stop() {
        notes.save(); media.stop(); system.stop(); agents.stop(); focus.stop(); calendar.stop(); camera.stop(); clipboard.stop(); bluetooth.cancel(); updates.stop(); downloads.stop(); cleanupTimer?.invalidate(); ambientTimer?.invalidate()
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
        guard preferences.showHUD else { return }
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

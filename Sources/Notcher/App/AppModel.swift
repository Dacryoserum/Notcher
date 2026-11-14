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
    let preferences = Preferences()
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
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    @Published var dragging = false
    @Published var dialogOpen = false
    /// Pointer resting on the closed notch in "hover then click" mode.
    @Published var hovering = false
    private var announcedTrack: NowPlaying.ArtworkKey?
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
    var visibleTabs: [NotchTab] { NotchTab.allCases.filter { $0 == .home || !preferences.hiddenTabs.contains($0.key) } }
    var collapsedWidth: CGFloat { collapsedSize.width }
    var width: CGFloat { expanded ? expandedWidth : collapsedWidth }
    var height: CGFloat { expanded ? notchHeight + pageHeight + 84 : collapsedSize.height + (activity?.details.isEmpty == false ? Self.detailHeight : 0) }

    func start() {
        agents.onLimit = { [weak self] title in self?.showActivity(.init(symbol: "sparkles", title: title, color: .orange), seconds: 6) }
        system.onVolumeChange = { [weak self] volume, muted in
            guard let self, self.preferences.showHUD else { return }
            let symbol = muted || volume <= 0 ? "speaker.slash.fill" : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            self.showActivity(.init(symbol: symbol, title: muted ? "Silence" : "Volume", value: muted ? 0 : volume), seconds: 1.6)
        }
        system.onPowerChange = { [weak self] charging in
            guard let self, self.preferences.showHUD else { return }
            let level = self.system.battery.map { Double($0) / 100 }
            self.showActivity(.init(symbol: charging ? "bolt.fill" : "battery.75percent", title: charging ? "En charge" : "Sur batterie", value: level), seconds: 3)
        }
        agents.onClaudeFinished = { [weak self] in
            guard let self, self.preferences.showHUD else { return }
            self.showActivity(.init(symbol: "asterisk", title: "", color: Theme.orange, artwork: ClaudeMark.icon, mark: "checkmark.circle.fill", markColor: Theme.green), seconds: 3.5)
            Haptics.play(.levelChange)
        }
        downloads.onFinished = { [weak self] path in
            guard let self, self.preferences.showHUD else { return }
            self.showActivity(.init(symbol: "doc.fill", title: "", artwork: DownloadWatcher.icon(for: path), mark: "arrow.down.circle.fill"), seconds: 3.5)
        }
        system.onHeadphones = { [weak self] name in self?.announceHeadphones(name) }
        // A new song is named in the closed notch for a moment; the first one seen at launch is not news.
        media.$track.sink { [weak self] track in
            guard let self else { return }
            let key = track?.artworkKey
            defer { if key != nil { self.announcedTrack = key } }
            guard let track, let previous = self.announcedTrack, previous != key, track.playing,
                  !self.expanded, self.preferences.announceTrack, !track.title.isEmpty else { return }
            self.showActivity(.init(symbol: "music.note", title: track.title), seconds: 3)
        }.store(in: &subscriptions)
        preferences.$mediaRestMinutes.sink { [weak self] value in self?.media.restMinutes = value }.store(in: &subscriptions)
        media.$resting.dropFirst().removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        $hovering.dropFirst().removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        focus.onFinished = { [weak self] in self?.showActivity(.init(symbol: "checkmark.circle.fill", title: "Pomodoro terminé"), seconds: 10) }
        shelf.onAdded = { [weak self] count in self?.notify(L(count > 1 ? "%lld éléments ajoutés au dépôt" : "%lld élément ajouté au dépôt", count)) }
        preferences.$haptics.sink { value in MainActor.assumeIsolated { Haptics.enabled = value } }.store(in: &subscriptions)
        preferences.$compactStyle.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        preferences.$hiddenTabs.sink { [weak self] hidden in
            guard let self, self.tab != .home, hidden.contains(self.tab.key) else { return }
            self.tab = .home
        }.store(in: &subscriptions)
        preferences.$mediaEnabled.sink { [weak self] value in self?.media.setEnabled(value) }.store(in: &subscriptions)
        preferences.$screenID.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        preferences.$panelSize.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.$retentionHours.dropFirst().sink { [weak self] value in self?.shelf.purge(hours: value) }.store(in: &subscriptions)
        preferences.$clipboardEnabled.dropFirst().sink { [weak self] value in if !value { self?.clipboard.clear() } }.store(in: &subscriptions)
        $expanded.dropFirst().removeDuplicates().sink { [weak self] value in
            if !value { self?.camera.stop(); self?.bluetooth.cancel() }
            self?.media.attentive = value
            self?.onGeometryChange?()
        }.store(in: &subscriptions)
        $activity.dropFirst().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        media.$track.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        focus.$clock.map { $0.deadline != nil }.removeDuplicates().sink { [weak self] _ in self?.onGeometryChange?() }.store(in: &subscriptions)
        // Published values change after their publisher fires: the state is recomputed on the next turn of the run loop.
        let sources: [AnyPublisher<Void, Never>] = [
            agents.$claudeWorking.map { _ in }.eraseToAnyPublisher(), agents.$claudeWaiting.map { _ in }.eraseToAnyPublisher(),
            agents.$claude.map { _ in }.eraseToAnyPublisher(), agents.$claudePromptAt.map { _ in }.eraseToAnyPublisher(), media.$track.map { _ in }.eraseToAnyPublisher(),
            media.$resting.map { _ in }.eraseToAnyPublisher(), focus.$clock.map { _ in }.eraseToAnyPublisher(),
            calendar.$events.map { _ in }.eraseToAnyPublisher(), system.$battery.map { _ in }.eraseToAnyPublisher(),
            system.$charging.map { _ in }.eraseToAnyPublisher(), system.$awake.map { _ in }.eraseToAnyPublisher(),
            preferences.$showHUD.map { _ in }.eraseToAnyPublisher()
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
        if agents.claudeWaiting > 0 {
            return NotchAmbient(symbol: "asterisk", artwork: ClaudeMark.icon, color: Theme.orange, mark: "hand.raised.fill", motion: .pulsing)
        }
        if focus.clock.deadline != nil { return nil }
        if agents.claudeWorking > 0, let asked = agents.claudePromptAt, now.timeIntervalSince(asked) < Self.claudeAnswerDisplay {
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
    func notify(_ value: String) {
        toastTask?.cancel(); toast = value
        toastTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(3)); self?.toast = nil } catch {} }
    }
}

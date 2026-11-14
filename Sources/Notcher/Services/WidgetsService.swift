import AppKit
@preconcurrency import AVFoundation
import EventKit
import NotcherCore
import UserNotifications

struct TaskItem: Codable, Identifiable {
    var id = UUID()
    var title: String
    var done = false
}

@MainActor final class FocusService: ObservableObject {
    @Published var clock: FocusClock
    @Published var now = Date()
    @Published var tasks: [TaskItem] = []
    @Published var error: String?
    private var timer: Timer?
    private let file = AppPaths.support.appendingPathComponent("focus.json")
    private var canSave = true
    private struct State: Codable { var clock: FocusClock; var tasks: [TaskItem] }
    var onFinished: (() -> Void)?
    init() {
        clock = FocusClock()
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                clock = state.clock; tasks = state.tasks
            } catch { self.error = "Le fichier des tâches est illisible. L’original est conservé."; canSave = false }
        }
    }
    var remaining: TimeInterval { clock.remaining(at: now) }
    var progress: Double { 1 - remaining / max(1, clock.duration) }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // A stopped timer has nothing to redraw: publishing anyway woke every view that shows it, each second.
                guard let self, self.clock.deadline != nil else { return }
                self.now = Date()
                if self.clock.finishIfNeeded(at: self.now) {
                    self.save(); NSSound(named: "Glass")?.play(); self.onFinished?()
                    let content = UNMutableNotificationContent(); content.title = L("Bien joué."); content.body = L("Ton minuteur Notcher est terminé."); content.sound = .default
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                }
            }
        }
        timer?.tolerance = 0.15
    }
    func stop() { timer?.invalidate(); timer = nil; save() }
    func toggle() {
        now = Date()
        if clock.deadline == nil {
            clock.start(at: now)
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        } else { clock.pause(at: now) }
        save()
    }
    func reset(minutes: Int? = nil) { clock.reset(duration: minutes.map { Double($0 * 60) }); now = Date(); save() }
    func addTask(_ title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }; tasks.append(TaskItem(title: value)); save()
    }
    func toggleTask(_ id: UUID) { if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].done.toggle(); save() } }
    func removeTask(_ id: UUID) { tasks.removeAll { $0.id == id }; save() }
    private func save() {
        guard canSave else { return }
        do { try JSONEncoder().encode(State(clock: clock, tasks: tasks)).write(to: file, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}

struct CalendarItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendarName: String
    let color: NSColor
    let meeting: URL?
}

@MainActor final class CalendarService: ObservableObject {
    @Published var events: [CalendarItem] = []
    @Published var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var error: String?
    @Published var loading = false
    @Published private(set) var month = Date()
    private let store = EKEventStore()
    private let reader = CalendarReader()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var readTask: Task<Void, Never>?
    private var generation = UUID()

    var nextEvent: CalendarItem? {
        let upcoming = events.filter { $0.end > Date() }
        return upcoming.first { !$0.allDay } ?? upcoming.first
    }
    func events(on day: Date) -> [CalendarItem] {
        events.filter { AgendaMonth.contains(start: $0.start, end: $0.end, on: day) }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            return $0.start < $1.start
        }
    }
    func showMonth(_ date: Date) {
        guard !Calendar.current.isDate(date, equalTo: month, toGranularity: .month) else { return }
        month = date; refresh()
    }
    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 5
        refresh()
    }
    func stop() { timer?.invalidate(); readTask?.cancel(); generation = UUID(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func requestAccess() {
        Task {
            do {
                authorized = try await store.requestFullAccessToEvents()
                // A store created before the permission was granted keeps answering "no events".
                if authorized { await reader.renew() }
                error = authorized ? nil : "Autorise Calendrier dans Réglages Système → Confidentialité et sécurité."
                refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    func refresh() {
        readTask?.cancel(); generation = UUID()
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let justGranted = granted && !authorized
        authorized = granted
        guard authorized else { events = []; loading = false; return }
        let token = generation
        let grid = AgendaMonth(containing: month)
        let today = Calendar.current.startOfDay(for: Date())
        let weekEnd = Calendar.current.date(byAdding: .day, value: 8, to: today)!
        // Keep the upcoming week available to the home card while browsing another month.
        let intervals = [grid.interval, DateInterval(start: today, end: weekEnd)]
        loading = true
        readTask = Task { [weak self, reader] in
            if justGranted { await reader.renew() } // Permission given from System Settings while running.
            let result = await reader.events(in: intervals)
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.events = result; self.loading = false
        }
    }
}

/// EventKit queries run off the UI actor. Only immutable event snapshots cross back.
private actor CalendarReader {
    private var store = EKEventStore()
    func renew() { store = EKEventStore() }
    func events(in intervals: [DateInterval]) -> [CalendarItem] {
        guard !Task.isCancelled else { return [] }
        var seen = Set<String>()
        return intervals.flatMap { interval in
            store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil))
        }.sorted { $0.startDate < $1.startDate }.compactMap { event in
            let id = (event.eventIdentifier ?? event.calendarItemIdentifier) + "-\(event.startDate.timeIntervalSince1970)"
            guard seen.insert(id).inserted else { return nil }
            return CalendarItem(id: id, title: event.title ?? L("Événement"), start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                                calendarName: event.calendar.title, color: NSColor(cgColor: event.calendar.cgColor) ?? .systemBlue, meeting: Self.meetingURL(event))
        }
    }
    private static func meetingURL(_ event: EKEvent) -> URL? {
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
            return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

@MainActor final class CameraService: ObservableObject {
    let session = AVCaptureSession()
    @Published var active = false
    @Published var error: String?
    private let queue = DispatchQueue(label: "fr.notcher.camera", qos: .userInitiated)
    private var requestID = UUID()
    func start() {
        let token = UUID(); requestID = token
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard requestID == token else { return }
            guard allowed else { error = "Autorise la caméra dans Réglages Système → Confidentialité et sécurité."; return }
            let session = session
            queue.async { [weak self] in
                do {
                    if session.inputs.isEmpty {
                        guard let device = AVCaptureDevice.default(for: .video) else { throw CommandError.failed("Aucune caméra disponible.") }
                        let input = try AVCaptureDeviceInput(device: device)
                        session.beginConfiguration()
                        session.sessionPreset = .medium
                        guard session.canAddInput(input) else { session.commitConfiguration(); throw CommandError.unavailable }
                        session.addInput(input); session.commitConfiguration()
                    }
                    session.startRunning()
                    Task { @MainActor in
                        guard let self else { return }
                        if self.requestID == token { self.active = true; self.error = nil }
                    }
                } catch { Task { @MainActor in self?.error = error.localizedDescription } }
            }
        }
    }
    func stop() { requestID = UUID(); active = false; let session = session; queue.async { if session.isRunning { session.stopRunning() } } }
}

struct ClipItem: Identifiable { let id = UUID(); let text: String; let date = Date(); let source: String }
@MainActor final class ClipboardService: ObservableObject {
    @Published var items: [ClipItem] = []
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private let preferences: Preferences
    init(preferences: Preferences) { self.preferences = preferences }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        timer?.tolerance = 0.3
    }
    func stop() { timer?.invalidate(); items.removeAll() }
    func clear() { items.removeAll(); changeCount = NSPasteboard.general.changeCount }
    func copy(_ item: ClipItem) { copyToClipboard(item.text); changeCount = NSPasteboard.general.changeCount }
    private func poll() {
        let board = NSPasteboard.general
        guard preferences.clipboardEnabled else { if !items.isEmpty { items.removeAll() }; changeCount = board.changeCount; return }
        guard changeCount != board.changeCount else { return }
        changeCount = board.changeCount
        let types = board.types?.map(\.rawValue) ?? []
        guard !types.contains(where: { $0.lowercased().contains("concealed") || $0.lowercased().contains("transient") || $0.lowercased().contains("password") }) else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier?.lowercased() ?? ""
        guard !["1password", "bitwarden", "keychainaccess", "keepass", "dashlane", "lastpass"].contains(where: bundle.contains) else { return }
        guard let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 50_000, items.first?.text != text else { return }
        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text, source: app?.localizedName ?? L("Application")), at: 0)
        items = Array(items.prefix(30))
    }
}

@MainActor final class ShortcutsService: ObservableObject {
    @Published var names: [String] = []
    @Published var running: String?
    @Published var error: String?
    func refresh() async {
        do {
            let output = try await Command.run("/usr/bin/shortcuts", ["list"])
            guard output.status == 0 else { throw CommandError.failed("Impossible de lire les raccourcis.") }
            names = output.text.split(separator: "\n").map(String.init).sorted(); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func run(_ name: String) {
        guard running == nil else { return }
        running = name
        Task {
            defer { running = nil }
            do {
                let result = try await Command.run("/usr/bin/shortcuts", ["run", name], timeout: 120)
                if result.status != 0 { throw CommandError.failed("Le raccourci a échoué ou a été annulé.") }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor final class BluetoothService: ObservableObject {
    @Published var connected: [String] = []
    @Published var loading = false
    @Published var error: String?
    private let client: HardwareClient
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(client: HardwareClient = .live) { self.client = client }
    func refresh() {
        guard !loading else { return }
        loading = true; error = nil
        let token = UUID(); generation = token
        task = Task {
            defer { if token == generation { loading = false; task = nil } }
            do {
                let value = try JSONDecoder().decode([String].self, from: await client.request(["bluetooth"]))
                try Task.checkCancellation()
                guard token == generation else { return }
                connected = value
            } catch is CancellationError {} catch {
                if token == generation { self.error = "Bluetooth indisponible" }
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
}

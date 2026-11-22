import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO
import CoreServices
import Network
import NotcherCore

/// Small observers behind the closed notch's announcements. None of them asks macOS for a permission:
/// they read states the system shares with every app (brightness, modifier keys, devices in use, network,
/// names of new files), never content.

/// Brightness keys, Control Centre or another app. Auto-brightness drifts by small steps and is left alone.
final class BrightnessWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.notcher.brightness", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var getter: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private var last: Double?
    /// After a deliberate change, the following small ones belong to the same gesture.
    private var followUntil = Date.distantPast
    private let onChange: @Sendable (Double) -> Void
    init(onChange: @escaping @Sendable (Double) -> Void) { self.onChange = onChange }
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            if getter == nil, let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
               let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
                getter = unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
            }
            guard getter != nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: .milliseconds(400), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.sample() }
            source.resume(); timer = source
        }
    }
    func stop() { queue.async { [self] in timer?.cancel(); timer = nil; last = nil } }
    /// Notcher's own slider moved it: no announcement for the next moment.
    func ignoreFor(_ seconds: Double) { queue.async { [self] in followUntil = .distantPast; last = nil; ignoreUntil = Date().addingTimeInterval(seconds) } }
    private var ignoreUntil = Date.distantPast
    private func sample() {
        guard let getter else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: 8), count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &displays, &count) == .success, let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { last = nil; return }
        var value: Float = 0
        guard getter(display, &value) == 0, value.isFinite else { return }
        let level = min(1, max(0, Double(value)))
        defer { last = level }
        guard let last, Date() > ignoreUntil else { return }
        let delta = abs(level - last)
        // A key press moves it by 1/16 at once; the ambient light sensor glides by a few hundredths.
        if delta >= 0.04 || (delta > 0.003 && Date() < followUntil) {
            followUntil = Date().addingTimeInterval(1.5)
            onChange(level)
        }
    }
}

/// Caps Lock, read from the modifier state every app can see; no keyboard monitoring.
@MainActor final class CapsLockWatcher {
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var state = false
    func start() {
        guard timer == nil else { return }
        state = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        timer?.tolerance = 0.08
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func sample() {
        let value = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        guard value != state else { return }
        state = value; onChange?(value)
    }
}

/// Which app records from a microphone, and whether a camera is on. CoreAudio lists the processes that use an
/// input; the camera only says it is running, so its user is guessed from the app in front.
final class CaptureWatcher: @unchecked Sendable {
    struct State: Equatable, Sendable { var microphone: [pid_t] = []; var camera = false }
    private let queue = DispatchQueue(label: "fr.notcher.capture", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var state = State()
    private var primed = false
    private let onChange: @Sendable (_ old: State, _ new: State) -> Void
    init(onChange: @escaping @Sendable (_ old: State, _ new: State) -> Void) { self.onChange = onChange }
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 2, repeating: .milliseconds(1500), leeway: .milliseconds(400))
            source.setEventHandler { [weak self] in self?.sample() }
            source.resume(); timer = source
        }
    }
    func stop() { queue.async { [self] in timer?.cancel(); timer = nil; primed = false; state = State() } }
    private func sample() {
        let next = State(microphone: Self.recordingProcesses(), camera: Self.cameraRunning())
        guard next != state else { return }
        let old = state; state = next
        // What is already in use at launch is not news.
        if primed { onChange(old, next) }
        primed = true
    }
    private static func recordingProcesses() -> [pid_t] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0, size < 65536 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return objects.compactMap { object in
            var running: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &running) == noErr, running != 0 else { return nil }
            var pid: pid_t = 0; bytes = UInt32(MemoryLayout<pid_t>.size)
            property.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &pid) == noErr, pid > 0, pid != me else { return nil }
            return pid
        }.sorted()
    }
    private static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0, size < 65536 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return false }
        return devices.contains { device in
            var property = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0, read: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &read, &running) == noErr && running != 0
        }
    }
    /// The app a process belongs to: browsers and video apps record from helper processes.
    @MainActor static func app(for pid: pid_t) -> NSRunningApplication? {
        guard let process = NSRunningApplication(processIdentifier: pid) else { return nil }
        if process.activationPolicy == .regular { return process }
        guard let helper = process.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
            return helper.hasPrefix(id + ".") || helper == id
        }.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }
}

/// The Mac loses or finds its Internet connection. Brief cuts (waking up, changing networks) are not announced.
@MainActor final class NetworkWatcher {
    var onChange: ((Bool) -> Void)?
    private var monitor: NWPathMonitor?
    private var online: Bool?
    private var announcedOffline = false
    private var pending: Task<Void, Never>?
    private var wokeAt = Date.distantPast
    private var wakeObserver: NSObjectProtocol?
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let value = path.status == .satisfied
            Task { @MainActor in self?.received(value) }
        }
        monitor.start(queue: DispatchQueue(label: "fr.notcher.network", qos: .utility))
        self.monitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeAt = Date() }
        }
    }
    func stop() {
        monitor?.cancel(); monitor = nil; pending?.cancel(); online = nil; announcedOffline = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }; wakeObserver = nil
    }
    private func received(_ value: Bool) {
        defer { online = value }
        guard let online, online != value else { return }
        pending?.cancel()
        if value {
            if announcedOffline { announcedOffline = false; onChange?(true) }
            return
        }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.online == false, Date().timeIntervalSince(self.wokeAt) > 20 else { return }
            self.announcedOffline = true; self.onChange?(false)
        }
    }
}

/// Screenshots and screen recordings saved by macOS, recognised from file-system events and their names:
/// the folder is never listed and the files are never opened. A capture copied to the clipboard instead
/// (Control in the shortcut, or a remapped shortcut) is recognised from the kinds of data on the clipboard and
/// from the capture tool being at work; the image itself is never read.
@MainActor final class ScreenshotWatcher {
    var onCapture: ((String) -> Void)?
    var onCopied: (() -> Void)?
    /// Tools whose image on the clipboard is a capture: macOS's own and the usual third-party ones.
    static let captureTools: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "cc.ffitch.shottr", "pl.maketheweb.cleanshotx",
                                             "com.monosnap.monosnap", "com.skitch.skitch", "com.flameshot", "com.xnapper.Xnapper"]
    private var boardTimer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var toolSeen = Date.distantPast
    private var appsObservation: NSKeyValueObservation?
    private var focusObservers: [NSObjectProtocol] = []
    private var stream: FSEventStreamRef?
    private var recent: [String: Date] = [:]
    private var customName: String?
    private var root = ""
    func start() {
        guard stream == nil else { return }
        changeCount = NSPasteboard.general.changeCount
        boardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollBoard() } }
        boardTimer?.tolerance = 0.15
        // The capture tool may already have quit when its image lands on the clipboard: remember when it was last around.
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] workspace, change in
            let apps = (change.oldValue ?? []) + (change.newValue ?? [])
            guard apps.contains(where: { ["com.apple.screencaptureui", "com.apple.screenshot.launcher"].contains($0.bundleIdentifier ?? "") }) else { return }
            Task { @MainActor in self?.toolSeen = Date() }
        }
        // A third-party tool copies when its editor closes (Shottr on Escape): it was in front a moment ago.
        focusObservers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, Self.captureTools.contains(app.bundleIdentifier ?? "") else { return }
                MainActor.assumeIsolated { self?.toolSeen = Date() }
            }
        }
        let settings = UserDefaults(suiteName: "com.apple.screencapture")
        customName = settings?.string(forKey: "name")
        let folder = (settings?.string(forKey: "location")).map { ($0 as NSString).expandingTildeInPath }.flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        guard let folder else { return }
        root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            let wanted = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            let touched = (0..<min(count, list.count)).filter { flags[$0] & wanted != 0 && flags[$0] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 }.map { list[$0] }
            guard !touched.isEmpty else { return }
            MainActor.assumeIsolated { Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue().received(touched) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return }
        stream = created
    }
    func stop() {
        boardTimer?.invalidate(); boardTimer = nil; appsObservation = nil
        focusObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; focusObservers = []
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    private func pollBoard() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        // Only the kinds of data are looked at: an image without a file behind it.
        let types = Set(board.types ?? [])
        guard types.contains(.png) || types.contains(.tiff), !types.contains(.fileURL) else { return }
        // Shottr, CleanShot… stay in the menu bar all day: only macOS's tool counts merely for running; the others
        // must be in front, where they put their editor after a capture.
        let running = NSWorkspace.shared.runningApplications.contains { ["com.apple.screencaptureui", "com.apple.screenshot.launcher"].contains($0.bundleIdentifier ?? "") && !$0.isTerminated }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { Self.captureTools.contains($0) } ?? false
        guard running || front || Date().timeIntervalSince(toolSeen) < 4 || Self.captureProcessRunning() else { return }
        onCopied?()
    }
    /// `screencapture` itself, which macOS starts for the keyboard shortcuts and which has no window.
    private static func captureProcessRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return false }
        var name = [CChar](repeating: 0, count: 64)
        return pids.prefix(Int(count)).contains { pid in proc_name(pid, &name, 64) > 0 && String(cString: name).hasPrefix("screencapture") }
    }
    private func received(_ paths: [String]) {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 600 }
        for path in paths where (path as NSString).deletingLastPathComponent == root && recent[path] == nil && ScreenshotWatch.isCapture(path, customName: customName, now: now) {
            recent[path] = now
            onCapture?(path)
        }
    }
}

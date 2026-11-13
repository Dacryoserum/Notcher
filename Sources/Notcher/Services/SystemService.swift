import AppKit
import NotcherCore

@MainActor final class SystemService: ObservableObject {
    @Published var volume: Double = 0
    @Published var muted = false
    @Published var canSetVolume = false
    @Published var canMute = false
    @Published var brightness: Double = 0.5
    @Published var canSetBrightness = false
    @Published var battery: Int?
    @Published var charging = false
    @Published var outputName = "Sortie audio"
    @Published var outputs: [AudioOutput] = []
    @Published var awake = false
    @Published var audioError: String?
    @Published var displayError: String?
    var onVolumeChange: ((Double, Bool) -> Void)?
    var onPowerChange: ((Bool) -> Void)?
    private let client: HardwareClient
    private var timer: Timer?
    private var initialized = false
    private var readTask: Task<Void, Never>?
    private var outputsTask: Task<Void, Never>?
    private var brightnessTask: Task<Void, Never>?
    private var brightnessReadTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var caffeinate: Process?
    private var lastFailure: Date?
    private var observer: VolumeObserver?
    private var lastLocalChange = Date.distantPast
    init(client: HardwareClient = .live) { self.client = client }

    func start() {
        guard timer == nil else { return }
        // Polling stays as a safety net; the observer delivers key presses immediately.
        let live = VolumeObserver { [weak self] volume, muted in Task { @MainActor in self?.applyLive(volume: volume, muted: muted) } }
        live.start(); observer = live
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 0.4
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observer?.stop(); observer = nil
        [readTask, outputsTask, brightnessReadTask, brightnessTask, volumeTask, controlTask].forEach { $0?.cancel() }
        if caffeinate?.isRunning == true { caffeinate?.terminate() }
        caffeinate = nil; awake = false
    }
    func refresh() {
        guard readTask == nil, lastFailure.map({ Date().timeIntervalSince($0) > 15 }) ?? true else { return }
        readTask = Task {
            defer { readTask = nil }
            do {
                let snapshot = try JSONDecoder().decode(AudioSnapshot.self, from: await client.request(["audio"]))
                try Task.checkCancellation()
                if initialized && volumeTask == nil && Date().timeIntervalSince(lastLocalChange) > 0.8 && (abs(volume - snapshot.volume) > 0.015 || muted != snapshot.muted) { onVolumeChange?(snapshot.volume, snapshot.muted) }
                let plugChanged = initialized && charging != snapshot.charging
                battery = snapshot.battery
                if plugChanged { onPowerChange?(snapshot.charging) }
                if volumeTask == nil { volume = snapshot.volume; muted = snapshot.muted }
                canSetVolume = snapshot.canSetVolume; canMute = snapshot.canMute
                outputName = snapshot.outputName; battery = snapshot.battery; charging = snapshot.charging
                initialized = true; audioError = nil; lastFailure = nil
            } catch is CancellationError {} catch {
                audioError = "Audio indisponible"; canSetVolume = false; canMute = false; lastFailure = Date()
            }
        }
    }
    private func applyLive(volume value: Double, muted state: Bool) {
        guard volumeTask == nil, abs(volume - value) > 0.0005 || muted != state else { return }
        volume = value; muted = state
        // A change made with Notcher's own slider needs no indicator.
        if initialized && Date().timeIntervalSince(lastLocalChange) > 0.8 { onVolumeChange?(value, state) }
    }
    func refreshOutputs() {
        guard outputsTask == nil else { return }
        outputsTask = Task {
            defer { outputsTask = nil }
            do {
                let value = try JSONDecoder().decode([AudioOutput].self, from: await client.request(["outputs"]))
                try Task.checkCancellation(); outputs = value
            } catch is CancellationError {} catch { audioError = "Sorties audio indisponibles" }
        }
    }
    func refreshBrightness() {
        guard brightnessReadTask == nil else { return }
        brightnessReadTask = Task {
            defer { brightnessReadTask = nil }
            do {
                let value = try JSONDecoder().decode(BrightnessSnapshot.self, from: await client.request(["brightness"]))
                try Task.checkCancellation()
                if brightnessTask == nil { brightness = value.value }
                canSetBrightness = value.supported; displayError = nil
            } catch is CancellationError {} catch { displayError = "Écran indisponible"; canSetBrightness = false }
        }
    }
    func changeVolume(_ value: Double) {
        guard canSetVolume else { return }
        volume = min(1, max(0, value)); volumeTask?.cancel(); lastLocalChange = Date()
        let target = volume
        volumeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(90))
                _ = try await client.request(["volume", String(target)])
                if muted && canMute && target > 0 { _ = try await client.request(["mute", "0"]); muted = false }
                try Task.checkCancellation(); volumeTask = nil; audioError = nil
            } catch is CancellationError {} catch { volumeTask = nil; audioError = "Volume indisponible" }
        }
    }
    func setMuted(_ value: Bool) { guard canMute else { return }; lastLocalChange = Date(); muted = value; control(["mute", value ? "1" : "0"]) }
    func selectOutput(_ output: AudioOutput) { control(["output", String(output.id)]) }
    private func control(_ arguments: [String]) {
        controlTask?.cancel()
        controlTask = Task {
            do {
                _ = try await client.request(arguments); try Task.checkCancellation()
                audioError = nil; lastFailure = nil; refresh()
            } catch is CancellationError {} catch { audioError = "Commande audio indisponible" }
        }
    }
    func changeBrightness(_ value: Double) {
        guard canSetBrightness else { return }
        brightness = min(1, max(0, value)); brightnessTask?.cancel()
        let target = brightness
        brightnessTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(90))
                _ = try await client.request(["set-brightness", String(target)])
                try Task.checkCancellation(); brightnessTask = nil; displayError = nil
            } catch is CancellationError {} catch { brightnessTask = nil; displayError = "Luminosité indisponible" }
        }
    }
    func toggleAwake() {
        if let process = caffeinate, process.isRunning { process.terminate(); caffeinate = nil; awake = false; return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in Task { @MainActor in if self?.caffeinate === child { self?.awake = false; self?.caffeinate = nil } } }
        do { try process.run(); caffeinate = process; awake = true } catch { audioError = error.localizedDescription }
    }
}

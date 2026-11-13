import AppKit
import NotcherCore

@MainActor final class CodexClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var generation = UUID()

    func connect(path customPath: String) async throws {
        if process?.isRunning == true { return }
        let executable = try Self.findExecutable(customPath)
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.currentDirectoryURL = AppPaths.support
        let token = UUID(); generation = token
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if !data.isEmpty { self.receive(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.disconnect()
            }
        }
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do {
            try process.run()
            _ = try await request("initialize", params: ["clientInfo": ["name": "notcher", "title": "Notcher", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"]])
            try send(["method": "initialized"])
        } catch { disconnect(); throw error }
    }
    func readLimits() async throws -> Data {
        let result = try await request("account/rateLimits/read", params: nil)
        return try JSONSerialization.data(withJSONObject: result)
    }
    func disconnect() {
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        let child = process
        if child?.isRunning == true { child?.terminate() }
        if let child {
            Task { try? await Task.sleep(for: .seconds(1)); if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        process = nil; input = nil; output = nil; buffer.removeAll()
        let outstanding = pending; pending.removeAll()
        for continuation in outstanding.values { continuation.resume(throwing: CommandError.failed("Connexion Codex interrompue.")) }
    }
    private func request(_ method: String, params: [String: Any]?) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            var message: [String: Any] = ["id": id, "method": method]
            if let params { message["params"] = params }
            do { try send(message) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.pending.removeValue(forKey: id)?.resume(throwing: CommandError.timeout)
            }
        }
    }
    private func send(_ message: [String: Any]) throws {
        guard let input else { throw CommandError.unavailable }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 4_000_000 else { disconnect(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: CommandError.failed(error["message"] as? String ?? "Codex ne peut pas lire les limites de ce compte."))
            } else { continuation.resume(returning: message["result"] as? [String: Any] ?? [:]) }
        }
    }
    static func findExecutable(_ custom: String) throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates = custom.isEmpty ? [] : [(custom as NSString).expandingTildeInPath]
        if !custom.isEmpty, fm.isExecutableFile(atPath: candidates[0]) { return candidates[0] }
        if !custom.isEmpty { throw CommandError.failed("Le chemin Codex choisi n’est pas exécutable.") }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.appendingPathComponent(".local/bin/codex").path, "/Applications/Codex.app/Contents/Resources/codex"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            candidates += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin/codex").path }
        }
        guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw CommandError.failed("Codex CLI introuvable. Indique son chemin dans les réglages.") }
        return path
    }
}

@MainActor final class AgentService: ObservableObject {
    @Published var claude: AgentUsage?
    @Published var codex: AgentUsage?
    @Published var codexStatus = "À connecter"
    @Published var claudeStatus = "À connecter"
    @Published var refreshing = false
    @Published var claudeInstalled = false
    private let client = CodexClient()
    private var timer: Timer?
    private var lastClaudeDate: Date?
    private var lastCodexRead = Date.distantPast
    var onLimit: ((String) -> Void)?
    private var alerted = Set<String>()
    let preferences: Preferences
    init(preferences: Preferences) { self.preferences = preferences }
    func start() {
        guard timer == nil else { return }
        claudeInstalled = FileManager.default.fileExists(atPath: AppPaths.integrations.appendingPathComponent("claude-install.json").path)
        readClaude()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.readClaude()
                if self.preferences.codexEnabled && Date().timeIntervalSince(self.lastCodexRead) >= 120 { await self.refreshCodex() }
            }
        }
        timer?.tolerance = 1
    }
    func stop() { timer?.invalidate(); timer = nil; client.disconnect() }
    func disconnectCodex() { preferences.codexEnabled = false; client.disconnect(); codexStatus = "Déconnecté" }
    func refreshCodex() async {
        guard !refreshing else { return }
        refreshing = true; codexStatus = "Actualisation…"; lastCodexRead = Date()
        defer { refreshing = false }
        do {
            try await client.connect(path: preferences.codexPath)
            let usage = try UsageParser.codex(await client.readLimits())
            codex = usage
            codexStatus = usage.windows.isEmpty ? "Quotas non fournis pour ce compte" : "Connecté · actualisation toutes les 2 min"
            checkLimits(usage)
        } catch { codexStatus = error.localizedDescription; client.disconnect() }
    }
    func readClaude() {
        let url = AppPaths.integrations.appendingPathComponent("claude.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let date = attrs[.modificationDate] as? Date, date != lastClaudeDate else { return }
        do {
            let value = try UsageParser.claude(Data(contentsOf: url), capturedAt: date)
            claude = value; lastClaudeDate = date
            claudeStatus = value.windows.isEmpty ? "En attente des quotas de Claude Code" : "Synchronisé après chaque réponse"
            checkLimits(value)
        } catch { claudeStatus = "Le relevé Claude Code est illisible." }
    }
    private func checkLimits(_ usage: AgentUsage) {
        for window in usage.windows where window.usedPercent >= 90 && !window.isExpired() {
            let key = "\(usage.provider)-\(window.id)-\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            if alerted.insert(key).inserted { onLimit?(L("%@ · %lld %% utilisés", usage.provider, Int(window.usedPercent))) }
        }
    }
    func installClaude() throws {
        try ClaudeIntegration.install()
        claudeInstalled = true; claudeStatus = "Connecté. Les quotas apparaîtront après la prochaine réponse de Claude Code ; une session déjà ouverte doit être relancée."
    }
    func uninstallClaude() throws {
        try ClaudeIntegration.uninstall()
        claudeInstalled = false; claudeStatus = "Intégration retirée"
    }
}

enum ClaudeIntegration {
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var recordURL: URL { AppPaths.integrations.appendingPathComponent("claude-install.json") }
    static func install(settingsURL: URL = settingsURL, recordURL: URL = recordURL, executablePath: String? = Bundle.main.executableURL?.path) throws {
        try AppPaths.prepare()
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            guard let loaded = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else { throw CommandError.failed("Le fichier settings.json de Claude n’est pas valide.") }
            settings = loaded
        }
        if fm.fileExists(atPath: recordURL.path) { throw CommandError.failed("L’intégration est déjà installée. Retire-la avant de la réinstaller.") }
        let original = settings["statusLine"]
        let previousCommand = (original as? [String: Any])?["command"] as? String
        if previousCommand?.contains("--claude-statusline") == true { throw CommandError.failed("Une intégration Notcher existe déjà dans Claude Code.") }
        guard let executable = executablePath else { throw CommandError.unavailable }
        let wrapper = AppPaths.integrations.appendingPathComponent("claude-statusline.sh")
        var script = "#!/bin/sh\ninput=$(cat)\nprintf '%s' \"$input\" | \(shellQuote(executable)) --claude-statusline"
        if let previousCommand, !previousCommand.isEmpty {
            script += " --quiet\nprintf '%s' \"$input\" | /bin/sh -c \(shellQuote(previousCommand))\n"
        } else { script += "\n" }
        let command = "/bin/sh " + shellQuote(wrapper.path)
        let record: [String: Any] = ["original": original ?? NSNull(), "installedCommand": command]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: recordURL, options: .atomic)
        do {
            try Data(script.utf8).write(to: wrapper, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            var statusLine = original as? [String: Any] ?? [:]
            statusLine["type"] = "command"; statusLine["command"] = command
            settings["statusLine"] = statusLine
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        } catch { try? fm.removeItem(at: recordURL); throw error }
    }
    static func uninstall(settingsURL: URL = settingsURL, recordURL: URL = recordURL) throws {
        guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any],
              var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any],
              let installed = record["installedCommand"] as? String,
              (settings["statusLine"] as? [String: Any])?["command"] as? String == installed else {
            throw CommandError.failed("Les réglages Claude ont changé depuis l’installation. Ils sont conservés ; retire la commande Notcher manuellement.")
        }
        if record["original"] is NSNull { settings.removeValue(forKey: "statusLine") } else { settings["statusLine"] = record["original"] }
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        try FileManager.default.removeItem(at: recordURL)
    }
}

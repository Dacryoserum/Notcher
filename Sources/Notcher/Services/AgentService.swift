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
    /// Claude Code sessions answering right now, and those stopped on a question or a permission.
    @Published private(set) var claudeWorking = 0
    @Published private(set) var claudeWaiting = 0
    /// When the last question was sent: the notch only shows that Claude is answering for a moment after it.
    @Published private(set) var claudePromptAt: Date?
    /// Helpers Claude Code started inside its sessions, oldest first.
    @Published private(set) var subagents: [ClaudeSubagent] = []
    /// Questions Claude Code is waiting on, oldest first; the notch shows the first one.
    @Published private(set) var permissionRequests: [PendingPermission] = []
    var onClaudeFinished: (() -> Void)?
    var onPermissionRequest: (() -> Void)?
    private let permissions = PermissionServer()
    private var sessions = ClaudeSessions()
    private var claudeObserver: NSObjectProtocol?
    private var alerted = Set<String>()
    let preferences: Preferences
    init(preferences: Preferences) { self.preferences = preferences }
    func start() {
        guard timer == nil else { return }
        claudeInstalled = FileManager.default.fileExists(atPath: AppPaths.integrations.appendingPathComponent("claude-install.json").path)
        // An integration installed by an earlier version only had the status line: add the hooks it lacks.
        if claudeInstalled { try? ClaudeIntegration.refreshHooks() }
        readClaude()
        permissions.onRequest = { [weak self] id, request in self?.ask(id, request) }
        permissions.onGone = { [weak self] id in self?.permissionRequests.removeAll { $0.id == id } }
        // Without the socket the hook finds nobody and Claude Code asks in the terminal, as it always did.
        try? permissions.start()
        claudeObserver = DistributedNotificationCenter.default().addObserver(forName: ClaudeRelay.name, object: nil, queue: .main) { [weak self] note in
            guard let event = ClaudeRelay.event(from: note.userInfo) else { return }
            Task { @MainActor in self?.receive(event) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.readClaude()
                self.sessions.prune(); self.publishSessions()
                if self.preferences.developerMode && self.preferences.codexEnabled && Date().timeIntervalSince(self.lastCodexRead) >= 120 { await self.refreshCodex() }
            }
        }
        timer?.tolerance = 1
    }
    func stop() {
        timer?.invalidate(); timer = nil; client.disconnect()
        permissions.stop(); permissionRequests = []
        if let claudeObserver { DistributedNotificationCenter.default().removeObserver(claudeObserver) }; claudeObserver = nil
    }
    func receive(_ event: ClaudeEvent, at now: Date = Date()) {
        guard preferences.developerMode else { return }
        let finished = sessions.apply(event, at: now)
        if event.kind == .prompt { claudePromptAt = now }
        publishSessions()
        if finished { onClaudeFinished?() }
    }
    private func publishSessions() {
        if claudeWorking != sessions.working { claudeWorking = sessions.working }
        if claudeWaiting != sessions.waiting { claudeWaiting = sessions.waiting }
        if subagents != sessions.subagents { subagents = sessions.subagents }
    }
    /// Leaves developer mode: nothing of Claude Code stays on screen, and open questions go back to the terminal.
    func silence() {
        sessions = ClaudeSessions(); publishSessions()
        releasePermissions()
        client.disconnect()
    }
    /// Hands every open question back to Claude Code's own prompt.
    func releasePermissions() {
        for pending in permissionRequests { permissions.reply(pending.id, .pass) }
        permissionRequests = []
    }
    private func ask(_ id: UUID, _ request: ClaudePermissionRequest) {
        guard preferences.developerMode, preferences.agentApprovals else { permissions.reply(id, .pass); return }
        permissionRequests.append(PendingPermission(id: id, request: request, received: Date()))
        onPermissionRequest?()
    }
    func answer(_ id: UUID, _ answer: ClaudePermissionAnswer) {
        guard permissionRequests.contains(where: { $0.id == id }) else { return }
        permissions.reply(id, answer)
        permissionRequests.removeAll { $0.id == id }
    }
    func disconnectCodex() {
        preferences.codexEnabled = false; client.disconnect(); codexStatus = "Déconnecté"
        try? CodexIntegration.uninstall()
    }
    func refreshCodex() async {
        guard !refreshing else { return }
        refreshing = true; codexStatus = "Actualisation…"; lastCodexRead = Date()
        defer { refreshing = false }
        // Codex asks the notch before it asks in the terminal, once its hook has been approved there (/hooks).
        try? CodexIntegration.install()
        do {
            try await client.connect(path: preferences.codexPath)
            let usage = try UsageParser.codex(await client.readLimits())
            codex = usage
            codexStatus = usage.windows.isEmpty ? "Quotas non fournis pour ce compte" : "Connecté · actualisation toutes les 2 min"
            checkLimits(usage)
        } catch { codexStatus = error.localizedDescription; client.disconnect() }
    }
    /// `force` reads the file again even when it has not changed, for a refresh asked by hand.
    func readClaude(force: Bool = false) {
        let url = AppPaths.integrations.appendingPathComponent("claude.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let date = attrs[.modificationDate] as? Date, force || date != lastClaudeDate else { return }
        do {
            let value = try UsageParser.claude(Data(contentsOf: url), capturedAt: date)
            claude = value; lastClaudeDate = date
            claudeStatus = value.windows.isEmpty ? "En attente des quotas de Claude Code" : "Synchronisé après chaque réponse"
            checkLimits(value)
        } catch { claudeStatus = "Le relevé Claude Code est illisible." }
    }
    /// The refresh button. Codex is asked again; Claude Code only sends its quotas after an answer, so its
    /// last reading is read again and the message says how old it is.
    func refreshAll() async -> String {
        readClaude(force: true)
        if preferences.codexEnabled { await refreshCodex() }
        var parts: [String] = []
        if claudeInstalled {
            if let claude {
                let time = claude.capturedAt.formatted(.dateTime.hour().minute())
                parts.append(claude.isStale() ? L("Claude Code : dernier relevé à %@, le prochain arrive avec sa prochaine réponse", time) : L("Claude Code : relevé de %@", time))
            } else { parts.append(L("Claude Code : aucun relevé pour l’instant, il arrive avec sa prochaine réponse")) }
        }
        if preferences.codexEnabled { parts.append(codex == nil ? L("Codex : %@", L(codexStatus)) : L("Codex : actualisé")) }
        return parts.isEmpty ? L("Connecte Claude Code ou Codex pour voir leurs limites") : parts.joined(separator: " · ")
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
        sessions = ClaudeSessions(); publishSessions()
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
        let wrapper = statusWrapper
        let script = statusScript(executable: executable, previousCommand: previousCommand)
        let command = "/bin/sh " + shellQuote(wrapper.path)
        let record: [String: Any] = ["original": original ?? NSNull(), "installedCommand": command]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: recordURL, options: .atomic)
        do {
            try Data(script.utf8).write(to: wrapper, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            var statusLine = original as? [String: Any] ?? [:]
            statusLine["type"] = "command"; statusLine["command"] = command
            settings["statusLine"] = statusLine
            try writeHookWrapper(executable: executable)
            addHooks(to: &settings)
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        } catch { try? fm.removeItem(at: recordURL); throw error }
    }
    static var statusWrapper: URL { AppPaths.integrations.appendingPathComponent("claude-statusline.sh") }
    /// The status line Claude Code runs after each answer: it hands the quotas to Notcher, then runs the
    /// status line the user had before, if any. A moved or deleted app must never break that one.
    static func statusScript(executable: String, previousCommand: String?) -> String {
        let previous = previousCommand.flatMap { $0.isEmpty ? nil : $0 }
        var script = "#!/bin/sh\ninput=$(cat)\nif [ -x \(shellQuote(executable)) ]; then printf '%s' \"$input\" | \(shellQuote(executable)) --claude-statusline\(previous == nil ? "" : " --quiet"); fi\n"
        if let previous { script += "printf '%s' \"$input\" | /bin/sh -c \(shellQuote(previous))\n" }
        return script
    }
    /// Claude Code events Notcher listens to: an answer starting, moving on, stopping on a question, ending.
    static let hookEvents = ClaudeEvent.Kind.allCases.map(\.rawValue)
    static var hookWrapper: URL { AppPaths.integrations.appendingPathComponent("claude-hook.sh") }
    static var hookCommand: String { "/bin/sh " + shellQuote(hookWrapper.path) }
    /// The hooks call this script rather than the app, so a moved or deleted app never breaks a Claude session.
    static func writeHookWrapper(executable: String) throws {
        for (wrapper, flag) in [(hookWrapper, "--claude-event"), (permissionWrapper, "--claude-permission")] {
            let script = "#!/bin/sh\n[ -x \(shellQuote(executable)) ] || exit 0\nexec \(shellQuote(executable)) \(flag)\n"
            guard (try? String(contentsOf: wrapper, encoding: .utf8)) != script else { continue }
            try Data(script.utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }
    }
    /// The one hook that waits for a person: it asks the notch and holds Claude Code's question meanwhile.
    static let permissionEvent = "PermissionRequest"
    static var permissionWrapper: URL { AppPaths.integrations.appendingPathComponent("claude-permission.sh") }
    static var permissionCommand: String { "/bin/sh " + shellQuote(permissionWrapper.path) }
    /// Every hook Notcher owns: the event, its command and how long Claude Code lets it run.
    private static var ownedHooks: [(event: String, command: String, timeout: Int)] {
        hookEvents.map { ($0, hookCommand, 5) } + [(permissionEvent, permissionCommand, 3600)]
    }
    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String).map { $0 == hookCommand || $0 == permissionCommand } ?? false } ?? false
    }
    /// Adds Notcher's entry next to the user's own hooks; true when something changed.
    @discardableResult static func addHooks(to settings: inout [String: Any]) -> Bool {
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return false }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for (event, command, timeout) in ownedHooks {
            guard hooks[event] == nil || hooks[event] is [Any] else { continue }
            var entries = hooks[event] as? [Any] ?? []
            guard !entries.contains(where: isOurs) else { continue }
            entries.append(["hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]]])
            hooks[event] = entries; changed = true
        }
        if changed { settings["hooks"] = hooks }
        return changed
    }
    /// Removes only Notcher's entries; true when something changed.
    @discardableResult static func removeHooks(from settings: inout [String: Any]) -> Bool {
        guard var hooks = settings["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (event, _, _) in ownedHooks {
            guard let entries = hooks[event] as? [Any], entries.contains(where: isOurs) else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept; changed = true
        }
        if changed { settings["hooks"] = hooks.isEmpty ? nil : hooks }
        return changed
    }
    /// Brings an existing installation up to date: the script follows the app, missing hooks are added.
    static func refreshHooks(settingsURL: URL = settingsURL, recordURL: URL = recordURL, executablePath: String? = Bundle.main.executableURL?.path) throws {
        guard let executable = executablePath,
              var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else { return }
        try writeHookWrapper(executable: executable)
        // The status line relay names the app too: without this, quotas stop arriving once the app has moved.
        if let record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))) as? [String: Any] {
            let script = statusScript(executable: executable, previousCommand: (record["original"] as? [String: Any])?["command"] as? String)
            if (try? String(contentsOf: statusWrapper, encoding: .utf8)) != script {
                try Data(script.utf8).write(to: statusWrapper, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusWrapper.path)
            }
        }
        if addHooks(to: &settings) {
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        }
    }
    static func uninstall(settingsURL: URL = settingsURL, recordURL: URL = recordURL) throws {
        // The hooks go even when the status line below can no longer be restored safely.
        if var current = try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any], removeHooks(from: &current) {
            try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        }
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

/// Codex reads its hooks from a file of its own, in the same shape as Claude Code's. Notcher only adds the one
/// that asks the notch before Codex asks in the terminal. Codex runs a new hook once it has been approved
/// there with /hooks.
enum CodexIntegration {
    static var hooksURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json") }
    static var wrapper: URL { AppPaths.integrations.appendingPathComponent("codex-permission.sh") }
    static var command: String { "/bin/sh " + shellQuote(wrapper.path) }
    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } ?? false
    }
    /// Reads the file; nil when it holds something Notcher does not understand, which is then left alone.
    private static func load(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
    }
    static func install(hooksURL: URL = hooksURL, executablePath: String? = Bundle.main.executableURL?.path) throws {
        guard let executable = executablePath else { throw CommandError.unavailable }
        try AppPaths.prepare()
        let script = "#!/bin/sh\n[ -x \(shellQuote(executable)) ] || exit 0\nexec \(shellQuote(executable)) --codex-permission\n"
        if (try? String(contentsOf: wrapper, encoding: .utf8)) != script {
            try Data(script.utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }
        guard var root = load(hooksURL), root["hooks"] == nil || root["hooks"] is [String: Any] else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        guard hooks["PermissionRequest"] == nil || hooks["PermissionRequest"] is [Any] else { return }
        var entries = hooks["PermissionRequest"] as? [Any] ?? []
        guard !entries.contains(where: isOurs) else { return }
        entries.append(["hooks": [["type": "command", "command": command, "timeout": 3600] as [String: Any]]])
        hooks["PermissionRequest"] = entries; root["hooks"] = hooks
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: hooksURL, options: .atomic)
    }
    /// Removes only Notcher's entry; a file that held nothing else is removed with it.
    static func uninstall(hooksURL: URL = hooksURL) throws {
        guard FileManager.default.fileExists(atPath: hooksURL.path), var root = load(hooksURL), var hooks = root["hooks"] as? [String: Any],
              let entries = hooks["PermissionRequest"] as? [Any], entries.contains(where: isOurs) else { return }
        let kept = entries.filter { !isOurs($0) }
        hooks["PermissionRequest"] = kept.isEmpty ? nil : kept
        root["hooks"] = hooks.isEmpty ? nil : hooks
        if root.isEmpty { try FileManager.default.removeItem(at: hooksURL) }
        else { try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: hooksURL, options: .atomic) }
    }
}

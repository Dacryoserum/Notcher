import AppKit
import NotcherCore

/// Network side of the updater. Only the GitHub API and release downloads are contacted, over HTTPS,
/// with nothing that identifies the user.
struct UpdateClient: Sendable {
    var fetch: @Sendable (URL) async throws -> Data
    static let live = UpdateClient { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notcher-Updater", forHTTPHeaderField: "User-Agent")
        // Downloaded to a file first: an oversized answer is refused before it is read into memory.
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CommandError.failed("Impossible de joindre GitHub.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= Updates.maximumArchiveSize else { throw UpdateError.tooLarge }
        return try Data(contentsOf: file)
    }
}

/// Puts a downloaded, already verified archive in place of a bundle. Works on any pair of folders, so the
/// tests exercise the real code on a throwaway bundle.
enum UpdateInstaller {
    /// Why the copy at `bundle` cannot replace itself, or nil.
    static func blocker(bundle: URL) -> String? {
        if bundle.path.contains("/AppTranslocation/") { return L("Déplace Notcher dans le dossier Applications pour pouvoir le mettre à jour.") }
        if bundle.pathExtension != "app" { return L("Cette copie de développement ne se met pas à jour toute seule.") }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) { return L("Notcher ne peut pas écrire dans le dossier où il est installé.") }
        return nil
    }
    private static func sibling(_ bundle: URL, _ suffix: String) -> URL { URL(fileURLWithPath: bundle.path + "." + suffix, isDirectory: true) }

    /// Unpacks `archive` and swaps it with `bundle`. The replaced copy is kept beside it with the `.old`
    /// suffix until the next start; if anything fails before the swap, `bundle` is untouched.
    static func install(archive: Data, version: String, over bundle: URL, checkCodeSignature: Bool = true) async throws {
        if let reason = blocker(bundle: bundle) { throw CommandError.failed(reason) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("notcher-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("update.zip"), unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try archive.write(to: zip)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let fresh = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw CommandError.failed("L’archive de mise à jour ne contient pas l’application.")
        }
        // The archive is signed, but a release built from the wrong folder must not replace the app either.
        let expected = (NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String) ?? "fr.notcher.app"
        guard let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == expected,
              let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), shipped == AppVersion(version),
              let executable = info["CFBundleExecutable"] as? String,
              fm.isExecutableFile(atPath: fresh.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path) else {
            throw CommandError.failed("L’archive de mise à jour ne correspond pas à la version annoncée.")
        }
        if checkCodeSignature { try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path]) }
        let staged = sibling(bundle, "update"), previous = sibling(bundle, "old")
        try? fm.removeItem(at: staged)
        // ditto keeps the bundle's permissions, symlinks and signature intact.
        do { try await run("/usr/bin/ditto", [fresh.path, staged.path]) } catch { try? fm.removeItem(at: staged); throw error }
        // Two renames inside one folder: each is atomic, and a failed second one puts the old copy back.
        try? fm.removeItem(at: previous)
        do { try fm.moveItem(at: bundle, to: previous) } catch { try? fm.removeItem(at: staged); throw error }
        do { try fm.moveItem(at: staged, to: bundle) } catch {
            try? fm.moveItem(at: previous, to: bundle); try? fm.removeItem(at: staged)
            throw error
        }
    }
    /// Deletes what an earlier update left beside `bundle`. Called at launch, once the new copy runs.
    static func cleanUp(bundle: URL) {
        guard bundle.pathExtension == "app" else { return }
        for suffix in ["old", "update"] { try? FileManager.default.removeItem(at: sibling(bundle, suffix)) }
    }
    private static func run(_ executable: String, _ arguments: [String]) async throws {
        let result = try await Command.run(executable, arguments, timeout: 120)
        guard result.status == 0 else { throw CommandError.failed("L’installation de la mise à jour a échoué.") }
    }
}

@MainActor final class UpdateService: ObservableObject {
    /// The newer version found, kept until it is installed.
    @Published private(set) var available: AvailableUpdate?
    /// Result of the last check, for the settings; nil before the first one.
    @Published private(set) var checkStatus: String?
    /// Progress or failure of the installation, already in the interface language.
    @Published private(set) var installStatus: String?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var failed = false
    let currentVersion: String
    private let client: UpdateClient
    private let bundle: URL
    private let relaunch: @MainActor (URL) -> Void
    private var timer: Timer?
    private var firstCheck: Task<Void, Never>?
    private var lastCheck = Date.distantPast
    private static let interval: TimeInterval = 24 * 3600

    init(client: UpdateClient = .live, currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         bundle: URL = Bundle.main.bundleURL, relaunch: @escaping @MainActor (URL) -> Void = UpdateService.relaunchApplication) {
        self.client = client; self.currentVersion = currentVersion; self.bundle = bundle; self.relaunch = relaunch
    }
    func start() {
        guard timer == nil, Updates.configured else { return }
        UpdateInstaller.cleanUp(bundle: bundle)
        // Not during launch: the notch comes first. Then once a day, counted in real time so that a Mac
        // that sleeps a lot still checks.
        firstCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastCheck) >= Self.interval else { return }
                self.check()
            }
        }
        timer?.tolerance = 300
    }
    func stop() { timer?.invalidate(); timer = nil; firstCheck?.cancel(); firstCheck = nil }

    /// Asks GitHub for a newer release. Silent unless the settings are open: only `checkStatus` changes.
    func check() {
        guard !checking, !installing else { return }
        guard Updates.configured else { checkStatus = L("Les mises à jour ne sont pas configurées dans cette copie."); return }
        checking = true; lastCheck = Date()
        Task {
            defer { checking = false }
            do {
                let found = try await Self.find(client: client, current: currentVersion)
                if let found {
                    if available != found { available = found; installStatus = nil; failed = false }
                    checkStatus = L("La version %@ est disponible.", found.version)
                } else if available == nil { checkStatus = L("Notcher est à jour.") }
            } catch { checkStatus = L("Impossible de joindre GitHub. Nouvel essai plus tard.") }
        }
    }
    /// Records an update found elsewhere (the tests feed one in without waiting for the daily check).
    func adopt(_ update: AvailableUpdate?) { available = update; installStatus = nil; failed = false }
    nonisolated static func find(client: UpdateClient, current: String) async throws -> AvailableUpdate? {
        let releases = try JSONDecoder().decode([GithubRelease].self, from: await client.fetch(Updates.releasesURL))
        guard let manifestURL = Updates.newestManifestURL(in: releases, current: current) else { return nil }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: await client.fetch(manifestURL))
        return Updates.update(from: manifest, current: current)
    }

    /// Downloads, verifies and installs the available version, then restarts on it.
    func install(publicKey: String = Updates.publicKey, checkCodeSignature: Bool = true) {
        guard !installing, let update = available else { return }
        if let reason = UpdateInstaller.blocker(bundle: bundle) { installStatus = reason; failed = true; return }
        installing = true; failed = false; installStatus = L("Téléchargement…")
        Task {
            do {
                guard let url = Updates.secureURL(update.asset.url) else { throw UpdateError.insecureAddress }
                let archive = try await client.fetch(url)
                installStatus = L("Vérification de la signature…")
                try await Task.detached(priority: .utility) { try Updates.verify(archive, asset: update.asset, publicKey: publicKey) }.value
                installStatus = L("Installation…")
                try await UpdateInstaller.install(archive: archive, version: update.version, over: bundle, checkCodeSignature: checkCodeSignature)
                installStatus = L("Redémarrage…")
                relaunch(bundle)
            } catch {
                installing = false; failed = true
                installStatus = L("Échec de la mise à jour : %@", error.localizedDescription)
            }
        }
    }
    /// Starts the new copy once this one has quit; `--relaunched` makes it wait instead of giving up.
    static func relaunchApplication(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.8; exec /usr/bin/open -n \"$0\" --args --relaunched", bundle.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }
}

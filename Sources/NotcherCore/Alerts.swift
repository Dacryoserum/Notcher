import Foundation

/// Every kind of event the closed notch can announce. Each one can be turned off on its own in the settings.
public enum NotchAlert: String, CaseIterable, Identifiable, Sendable {
    case volume, brightness, capsLock, power, battery, headphones, network, microphone, camera, screenshot, download
    case calendar, awake, timer, claudeDone, claudeIdle, claudeShipped
    public var id: String { rawValue }
    public enum Group: CaseIterable, Sendable { case mac, activity, claude }
    public var group: Group {
        switch self {
        case .volume, .brightness, .capsLock, .power, .battery, .headphones, .network: return .mac
        case .microphone, .camera, .screenshot, .download, .calendar, .awake, .timer: return .activity
        case .claudeDone, .claudeIdle, .claudeShipped: return .claude
        }
    }
    /// French text, translated where it is displayed.
    public var title: String {
        switch self {
        case .volume: return "Volume et sourdine"
        case .brightness: return "Luminosité de l’écran"
        case .capsLock: return "Verrouillage des majuscules"
        case .power: return "Chargeur branché ou débranché"
        case .battery: return "Batterie faible ou chargée"
        case .headphones: return "Écouteurs connectés ou déconnectés"
        case .network: return "Connexion Internet perdue ou retrouvée"
        case .microphone: return "Micro utilisé par une app"
        case .camera: return "Caméra allumée"
        case .screenshot: return "Capture d’écran enregistrée"
        case .download: return "Téléchargement terminé"
        case .calendar: return "Rendez-vous qui commence"
        case .awake: return "Fin du maintien en éveil"
        case .timer: return "Fin du minuteur"
        case .claudeDone: return "Claude a terminé"
        case .claudeIdle: return "Claude attend ta réponse"
        case .claudeShipped: return "Commit, push, PR et déploiement"
        }
    }
    public var symbol: String {
        switch self {
        case .volume: return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .capsLock: return "capslock.fill"
        case .power: return "bolt.fill"
        case .battery: return "battery.25percent"
        case .headphones: return "airpods"
        case .network: return "wifi"
        case .microphone: return "mic.fill"
        case .camera: return "video.fill"
        case .screenshot: return "camera.viewfinder"
        case .download: return "arrow.down.circle.fill"
        case .calendar: return "calendar"
        case .awake: return "cup.and.saucer.fill"
        case .timer: return "timer"
        case .claudeDone: return "checkmark.circle.fill"
        case .claudeIdle: return "bubble.left.fill"
        case .claudeShipped: return "arrow.up.circle.fill"
        }
    }
}

/// Announces a battery running low once per threshold, and a full charge once per charge.
public struct BatteryWatch: Equatable, Sendable {
    public enum Event: Equatable, Sendable { case low(Int), full }
    public static let thresholds = [20, 10]
    private var last: Int?
    private var warned = Set<Int>()
    private var fullAnnounced = false
    public init() {}
    /// The first reading only sets the starting point: a Mac opened at 15 % is not warned at launch.
    public mutating func update(level: Int, charging: Bool) -> Event? {
        defer { last = level }
        if charging {
            warned = warned.filter { level <= $0 }
            guard level >= 100, !fullAnnounced else { return nil }
            fullAnnounced = true
            // Plugged in while already full, or full at launch: nothing has just happened.
            return (last ?? 100) < 100 ? .full : nil
        }
        fullAnnounced = false
        guard let last else { warned = Set(Self.thresholds.filter { level <= $0 }); return nil }
        let crossed = Self.thresholds.filter { level <= $0 && level < last && !warned.contains($0) }
        guard !crossed.isEmpty else { return nil }
        warned.formUnion(crossed)
        return .low(level)
    }
}

/// Recognises a screenshot or a screen recording saved by macOS, from its name alone.
public enum ScreenshotWatch {
    /// The names macOS gives in the languages it ships, plus the one chosen with `defaults write com.apple.screencapture name`.
    static let prefixes = ["Screenshot", "Screen Shot", "Screen Recording", "Capture d’écran", "Capture d'écran", "Enregistrement de l’écran",
                           "Enregistrement de l'écran", "Bildschirmfoto", "Bildschirmaufnahme", "Captura de pantalla", "Grabación de pantalla",
                           "Schermata", "Registrazione schermo", "Captura de Tela", "Gravação de Tela", "Schermafbeelding", "Skärmavbild", "スクリーンショット", "截屏", "螢幕截圖"]
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf", "mov", "mp4"]
    /// A file renamed in the folder is either a capture being saved or an old one being moved to the Bin: the time
    /// written in its name tells them apart without opening the folder.
    public static func isCapture(_ path: String, customName: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), extensions.contains((name as NSString).pathExtension.lowercased()) else { return false }
        let custom = customName.flatMap { $0.isEmpty ? nil : $0 }
        guard (prefixes + (custom.map { [$0] } ?? [])).contains(where: { name.hasPrefix($0) }) else { return false }
        return isRecent(name, now: now, calendar: calendar)
    }
    /// True when the name holds no date (the user turned it off) or a date within two minutes of now.
    static func isRecent(_ name: String, now: Date, calendar: Calendar) -> Bool {
        guard let date = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return true }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard String(name[date]) == String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) else { return false }
        guard let time = name[date.upperBound...].range(of: #"\d{1,2}[.:h]\d{2}"#, options: .regularExpression) else { return true }
        let digits = name[time].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count == 2 else { return true }
        let current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // 12-hour names ("2.03.11 PM") match either half of the day.
        return [digits[0] % 12, digits[0] % 12 + 12].contains { abs($0 * 60 + digits[1] - current) <= 2 }
    }
}

/// What a shell command run by Claude Code ships, if anything. Only the category leaves the hook; the command never does.
public enum ShipAction: String, Sendable, CaseIterable {
    case commit, push, pullRequest = "pr", deploy
    public var symbol: String {
        switch self {
        case .commit: return "checkmark.seal.fill"
        case .push: return "arrow.up.circle.fill"
        case .pullRequest: return "arrow.triangle.pull"
        case .deploy: return "paperplane.fill"
        }
    }
    /// French text, translated where it is displayed.
    public var title: String {
        switch self {
        case .commit: return "Commit créé"
        case .push: return "Push envoyé"
        case .pullRequest: return "Pull request ouverte"
        case .deploy: return "Déploiement lancé"
        }
    }
    public var failure: String {
        switch self {
        case .commit: return "Commit échoué"
        case .push: return "Push refusé"
        case .pullRequest: return "Pull request échouée"
        case .deploy: return "Déploiement échoué"
        }
    }
    /// The most visible thing the command does: a push after a commit is announced as the push.
    public static func classify(_ command: String) -> ShipAction? {
        let separators = CharacterSet(charactersIn: ";|&\n()")
        let found = command.components(separatedBy: separators).compactMap { segment -> ShipAction? in
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            // Environment assignments and wrappers in front of the command.
            while let first = words.first, first.contains("=") || ["env", "sudo", "command", "time", "npx", "bunx", "pnpm", "yarn"].contains(first) { words.removeFirst() }
            guard let tool = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
            var rest = Array(words.dropFirst())
            switch tool {
            case "git":
                // Global options before the subcommand, some of which take a value.
                while let option = rest.first, option.hasPrefix("-") {
                    rest.removeFirst()
                    if ["-C", "-c", "--git-dir", "--work-tree"].contains(option), !rest.isEmpty { rest.removeFirst() }
                }
                switch rest.first {
                case "commit": return rest.contains("--dry-run") ? nil : .commit
                case "push": return rest.contains("--dry-run") || rest.contains("-n") ? nil : .push
                default: return nil
                }
            case "gh", "glab":
                return rest.count >= 2 && ["pr", "mr"].contains(rest[0]) && rest[1] == "create" ? .pullRequest : nil
            case "vercel", "netlify", "fly", "flyctl", "wrangler", "railway", "firebase":
                return rest.contains("deploy") || rest.contains("--prod") || rest.contains("up") || (tool == "vercel" && rest.isEmpty) ? .deploy : nil
            default: return nil
            }
        }
        let order: [ShipAction] = [.deploy, .pullRequest, .push, .commit]
        return order.first { found.contains($0) }
    }
}

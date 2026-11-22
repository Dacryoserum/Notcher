import SwiftUI
import ServiceManagement
import NotcherCore

@MainActor final class Preferences: ObservableObject {
    @Published var homeLayout: HomeLayout { didSet { defaults.set(homeLayout.encoded, forKey: "homeLayout") } }
    @Published var openMode: OpenMode { didSet { defaults.set(openMode.rawValue, forKey: "openMode") } }
    @Published var mediaRestMinutes: Int { didSet { defaults.set(mediaRestMinutes, forKey: "mediaRestMinutes") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var mediaEnabled: Bool { didSet { defaults.set(mediaEnabled, forKey: "mediaEnabled") } }
    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var retentionHours: Int { didSet { defaults.set(retentionHours, forKey: "retentionHours") } }
    @Published var screenID: Int { didSet { defaults.set(screenID, forKey: "screenID") } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    @Published var codexEnabled: Bool { didSet { defaults.set(codexEnabled, forKey: "codexEnabled") } }
    /// Everything about AI coding agents (the Agents tab, quotas, Claude Code and Codex connections, questions
    /// answered from the notch) only exists in developer mode.
    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    /// Agents chosen on the Agents page ("claude", "codex", "both"); empty until the first visit asks.
    @Published var agentChoice: String { didSet { defaults.set(agentChoice, forKey: "agentChoice") } }
    var chosenAgents: [AgentKind] {
        switch agentChoice { case "claude": return [.claude]; case "codex": return [.codex]; case "both": return [.claude, .codex]; default: return [] }
    }
    /// Claude Code's permission questions can be answered in the notch.
    @Published var agentApprovals: Bool { didSet { defaults.set(agentApprovals, forKey: "agentApprovals") } }
    @Published var clockStyle: ClockStyle { didSet { defaults.set(clockStyle.rawValue, forKey: "clockStyle") } }
    /// The minutes of the clock widget take the accent colour.
    @Published var clockTwoTone: Bool { didSet { defaults.set(clockTwoTone, forKey: "clockTwoTone") } }
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: "showHUD") } }
    /// Announcements turned off one by one (`NotchAlert` raw values).
    @Published var mutedAlerts: Set<String> { didSet { defaults.set(mutedAlerts.sorted(), forKey: "mutedAlerts") } }
    @Published var dashboardLayout: DashboardLayout { didSet { defaults.set(dashboardLayout.rawValue, forKey: "dashboardLayout") } }
    @Published var panelSize: PanelSize { didSet { defaults.set(panelSize.rawValue, forKey: "panelSize") } }
    @Published var navigationStyle: NavigationStyle { didSet { defaults.set(navigationStyle.rawValue, forKey: "navigationStyle") } }
    @Published var accentHex: String { didSet { defaults.set(accentHex, forKey: "accentHex") } }
    @Published var motionStyle: MotionStyle { didSet { defaults.set(motionStyle.rawValue, forKey: "motionStyle") } }
    @Published var closeDelay: CloseDelay { didSet { defaults.set(closeDelay.rawValue, forKey: "closeDelay") } }
    @Published var compactStyle: CompactStyle { didSet { defaults.set(compactStyle.rawValue, forKey: "compactStyle") } }
    /// Stable tab keys, never display names: a renamed tab must not reappear.
    @Published var hiddenTabs: Set<String> { didSet { defaults.set(hiddenTabs.sorted(), forKey: "hiddenTabs") } }
    /// Global shortcut that opens or closes the panel.
    @Published var hotKey: HotKeyCombo { didSet { defaults.set(hotKey.encoded, forKey: "hotKey") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// "system", "fr" or "en". Stored as the standard AppleLanguages override; applies at next launch.
    @Published var language: String {
        didSet {
            if language == "system" { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([language], forKey: "AppleLanguages") }
            defaults.set(language, forKey: "appLanguage")
        }
    }
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["openOnHover": true, "mediaRestMinutes": 5, "haptics": true, "mediaEnabled": true, "retentionHours": 24, "showHUD": true, "clockTwoTone": true, "agentApprovals": true])
        let chosen = defaults.string(forKey: "appLanguage") ?? "system"
        language = ["fr", "en"].contains(chosen) ? chosen : "system"
        homeLayout = HomeLayout.restore(defaults.data(forKey: "homeLayout"))
        // Versions before 1.0 only knew "open on hover" on or off.
        openMode = OpenMode(rawValue: defaults.string(forKey: "openMode") ?? "") ?? (defaults.bool(forKey: "openOnHover") ? .hover : .click)
        let rest = defaults.integer(forKey: "mediaRestMinutes")
        mediaRestMinutes = MediaRest.choices.contains(rest) ? rest : 5
        haptics = defaults.bool(forKey: "haptics")
        mediaEnabled = defaults.bool(forKey: "mediaEnabled"); clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")
        retentionHours = defaults.integer(forKey: "retentionHours"); screenID = defaults.integer(forKey: "screenID")
        codexPath = defaults.string(forKey: "codexPath") ?? ""; codexEnabled = defaults.bool(forKey: "codexEnabled")
        // Someone who already connected an agent keeps everything they had before developer mode existed.
        let connected = defaults.bool(forKey: "codexEnabled") || FileManager.default.fileExists(atPath: AppPaths.integrations.appendingPathComponent("claude-install.json").path)
        developerMode = defaults.object(forKey: "developerMode") == nil ? connected : defaults.bool(forKey: "developerMode")
        agentApprovals = defaults.bool(forKey: "agentApprovals")
        agentChoice = ["claude", "codex", "both"].contains(defaults.string(forKey: "agentChoice") ?? "") ? defaults.string(forKey: "agentChoice")! : ""
        clockStyle = ClockStyle(rawValue: defaults.string(forKey: "clockStyle") ?? "") ?? .tall
        clockTwoTone = defaults.bool(forKey: "clockTwoTone")
        showHUD = defaults.bool(forKey: "showHUD")
        mutedAlerts = Set(defaults.stringArray(forKey: "mutedAlerts") ?? [])
        dashboardLayout = DashboardLayout(rawValue: defaults.string(forKey: "dashboardLayout") ?? "") ?? .overview
        panelSize = PanelSize(rawValue: defaults.string(forKey: "panelSize") ?? "") ?? .compact
        navigationStyle = NavigationStyle(rawValue: defaults.string(forKey: "navigationStyle") ?? "") ?? .labels
        accentHex = AccentColor(hex: defaults.string(forKey: "accentHex") ?? "")?.hex ?? AccentColor.default.hex
        motionStyle = MotionStyle(rawValue: defaults.string(forKey: "motionStyle") ?? "") ?? .smooth
        closeDelay = CloseDelay(rawValue: defaults.string(forKey: "closeDelay") ?? "") ?? .normal
        compactStyle = CompactStyle(rawValue: defaults.string(forKey: "compactStyle") ?? "") ?? .minimal
        hiddenTabs = Set(defaults.stringArray(forKey: "hiddenTabs") ?? [])
        hotKey = HotKeyCombo.restore(defaults.data(forKey: "hotKey"))
    }
    /// The closed notch may announce this kind of event.
    func allows(_ alert: NotchAlert) -> Bool {
        guard showHUD, !mutedAlerts.contains(alert.rawValue) else { return false }
        return alert.group != .claude || developerMode
    }
    func setAlert(_ alert: NotchAlert, enabled: Bool) {
        if enabled { mutedAlerts.remove(alert.rawValue) } else { mutedAlerts.insert(alert.rawValue) }
    }
    var accentColor: Color {
        let color = AccentColor(hex: accentHex) ?? .default
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
    func setAccent(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        accentHex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    /// A tab whose content already sits on the overview as a widget is named after what only it offers.
    func title(for tab: NotchTab) -> String {
        guard dashboardLayout == .overview else { return L(tab.rawValue) }
        switch tab {
        case .notes where homeLayout.contains(.note): return L("Fiches")
        case .files where homeLayout.contains(.files): return L("Fichiers")
        case .agents where homeLayout.contains(.agents): return L("Détails")
        default: return L(tab.rawValue)
        }
    }
    func resetAppearance() {
        accentHex = AccentColor.default.hex
        dashboardLayout = .overview; panelSize = .compact; navigationStyle = .labels
        motionStyle = .smooth; compactStyle = .minimal; hiddenTabs = []
    }
    func setLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

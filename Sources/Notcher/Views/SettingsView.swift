import SwiftUI
import NotcherCore

struct SettingsView: View {
    static let size = CGSize(width: 720, height: 690)
    enum Pane: String, CaseIterable, Identifiable {
        case look = "Apparence", widgets = "Widgets", behavior = "Comportement", services = "Services"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .look: return "paintpalette"
            case .widgets: return "square.grid.2x2"
            case .behavior: return "cursorarrow.motionlines"
            case .services: return "puzzlepiece.extension"
            }
        }
    }
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: Preferences
    @ObservedObject private var agents: AgentService
    @State private var pane: Pane
    @State private var error: String?
    @Namespace private var paneMarker
    init(model: AppModel, pane: Pane = .look) {
        self.model = model; preferences = model.preferences; agents = model.agents
        _pane = State(initialValue: pane)
    }
    private var accent: Color { preferences.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                Group {
                    switch pane {
                    case .look: AppearancePane(preferences: preferences)
                    case .widgets: WidgetsPane(preferences: preferences)
                    case .behavior: BehaviorPane(preferences: preferences, error: $error)
                    case .services: ServicesPane(preferences: preferences, agents: agents, error: $error)
                    }
                }.padding(.horizontal, 28).padding(.vertical, 22)
            }.scrollIndicators(.automatic)
            if let error {
                ErrorLine(message: error).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 10).background(Theme.surface)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(white: 0.055))
        .foregroundStyle(.white)
        .environment(\.notcherAccent, accent).tint(accent)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Text("Réglages").font(.system(size: 20, weight: .semibold)).fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(Pane.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { pane = item }
                        error = nil
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).frame(height: 30)
                            .foregroundStyle(pane == item ? accent.contrastingText : Color.white.opacity(0.65))
                            .background { if pane == item { Capsule().fill(accent).matchedGeometryEffect(id: "pane", in: paneMarker) } }
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(pane == item ? .isSelected : [])
                }
            }.padding(3).background(Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
            Spacer(minLength: 0)
            Text("Notcher \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize()
        }.padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 16)
    }
}

// MARK: - Apparence

private struct AppearancePane: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var preferences: Preferences
    @State private var motionDemo: [MotionStyle: Int] = [:]
    private let palette = ["B3EDA8", "7FE0D2", "87BAFF", "C4A7FF", "F3A5CC", "F28B82", "F1BC7A", "E4E4E7"]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            NotchPreview(preferences: preferences)
            SettingsGroup(title: "Couleur") {
                HStack(spacing: 10) {
                    ForEach(palette, id: \.self) { hex in swatch(hex) }
                    Spacer(minLength: 8)
                    ColorPicker("Autre couleur", selection: Binding(get: { accent }, set: preferences.setAccent), supportsOpacity: false)
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
            }
            SettingsGroup(title: "Disposition de l’aperçu", hint: "« Complet » se compose dans l’onglet Widgets") {
                HStack(spacing: 10) {
                    ForEach(DashboardLayout.allCases) { layout in
                        OptionTile(title: layout.title, selected: preferences.dashboardLayout == layout) { preferences.dashboardLayout = layout } art: {
                            LayoutArt(layout: layout).frame(width: 104, height: 50)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 22) {
                SettingsGroup(title: "Taille du panneau") {
                    HStack(spacing: 10) {
                        ForEach(PanelSize.allCases) { size in
                            OptionTile(title: size.title, selected: preferences.panelSize == size) { preferences.panelSize = size } art: { SizeArt(size: size) }
                        }
                    }
                }
                SettingsGroup(title: "Onglets") {
                    HStack(spacing: 10) {
                        ForEach(NavigationStyle.allCases) { style in
                            OptionTile(title: style.title, selected: preferences.navigationStyle == style) { preferences.navigationStyle = style } art: { NavigationArt(style: style) }
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 22) {
                SettingsGroup(title: "Notch fermé", hint: "Au repos") {
                    HStack(spacing: 10) {
                        ForEach(CompactStyle.allCases) { style in
                            OptionTile(title: style.title, selected: preferences.compactStyle == style) { preferences.compactStyle = style } art: { CompactArt(style: style) }
                        }
                    }
                }
                SettingsGroup(title: "Animation", hint: "Survole pour voir") {
                    HStack(spacing: 10) {
                        ForEach(MotionStyle.allCases) { style in
                            OptionTile(title: style.title, selected: preferences.motionStyle == style) {
                                preferences.motionStyle = style; motionDemo[style, default: 0] += 1
                            } art: { MotionArt(style: style, trigger: motionDemo[style, default: 0]) }
                            .onHover { inside in if inside { motionDemo[style, default: 0] += 1 } }
                        }
                    }
                }
            }
            SettingsGroup(title: "Onglets affichés", hint: "Clique pour masquer ou afficher") {
                HStack(spacing: 8) {
                    ForEach(NotchTab.allCases) { tab in tabChip(tab) }
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Spacer()
                CapsuleButton(title: "Réinitialiser l’apparence", symbol: "arrow.counterclockwise") { preferences.resetAppearance() }
            }
        }
    }
    private func swatch(_ hex: String) -> some View {
        let rgb = AccentColor(hex: hex) ?? .default
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let selected = preferences.accentHex == rgb.hex
        return Button { preferences.accentHex = rgb.hex; Haptics.play(.alignment) } label: {
            ZStack {
                Circle().strokeBorder(color.opacity(selected ? 1 : 0), lineWidth: 2).frame(width: 36, height: 36)
                Circle().fill(color).frame(width: 26, height: 26)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(color.contrastingText) }
            }.frame(width: 36, height: 36).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel("Couleur #" + hex).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func tabChip(_ tab: NotchTab) -> some View {
        let locked = tab == .home
        let visible = locked || !preferences.hiddenTabs.contains(tab.key)
        return Button {
            if visible { preferences.hiddenTabs.insert(tab.key) } else { preferences.hiddenTabs.remove(tab.key) }
            Haptics.play(.alignment)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol).font(.system(size: 11))
                Text(preferences.title(for: tab)).font(.system(size: 11, weight: .medium)).strikethrough(!visible)
                Image(systemName: locked ? "lock.fill" : visible ? "eye" : "eye.slash").font(.system(size: 9)).opacity(0.7)
            }
            .padding(.horizontal, 11).frame(height: 30)
            .foregroundStyle(visible ? accent : Theme.muted)
            .background(visible ? accent.opacity(0.10) : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(visible ? accent.opacity(0.35) : Theme.border))
            .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(locked)
            .help(locked ? "L’aperçu reste toujours affiché" : visible ? "Masquer cet onglet" : "Afficher cet onglet")
            .accessibilityLabel(tab.rawValue).accessibilityValue(visible ? "Affiché" : "Masqué")
    }
}

/// A miniature Mac screen whose notch reacts to every appearance choice.
private struct NotchPreview: View {
    @Environment(\.notcherAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var preferences: Preferences
    @State private var open = true
    @State private var replay: Task<Void, Never>?
    private var comfortable: Bool { preferences.panelSize == .comfortable }
    private var openSize: CGSize { comfortable ? CGSize(width: 330, height: 156) : CGSize(width: 288, height: 134) }
    private var closedSize: CGSize { CGSize(width: preferences.compactStyle == .info ? 150 : 86, height: 18) }
    private var spring: Animation? {
        guard !reduceMotion else { return nil }
        let value = open ? preferences.motionStyle.opening : preferences.motionStyle.closing
        return .spring(response: value.response, dampingFraction: value.damping)
    }
    private var tabs: [NotchTab] { NotchTab.allCases.filter { $0 == .home || !preferences.hiddenTabs.contains($0.key) } }
    var body: some View {
        let size = open ? openSize : closedSize
        ZStack(alignment: .top) {
            LinearGradient(colors: [accent.opacity(0.42), Color(red: 0.10, green: 0.13, blue: 0.20), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 7) {
                Image(systemName: "apple.logo").font(.system(size: 8))
                ForEach([22, 16, 26, 18], id: \.self) { width in Capsule().frame(width: CGFloat(width), height: 3) }
                Spacer()
                ForEach(["wifi", "battery.75percent", "magnifyingglass"], id: \.self) { Image(systemName: $0).font(.system(size: 8)) }
            }.foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 12).frame(height: 18).background(.black.opacity(0.22))
            VStack(spacing: 0) {
                HStack {
                    if preferences.compactStyle == .info || open { Text(Date(), format: .dateTime.day().month(.abbreviated)) }
                    Spacer(minLength: 56)
                    if preferences.compactStyle == .info || open { Text(Date(), format: .dateTime.hour().minute()) }
                }.font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    .padding(.horizontal, open ? 16 : 9).frame(width: size.width, height: 18)
                VStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(tabs) { tab in
                            HStack(spacing: 3) {
                                Image(systemName: tab.symbol).font(.system(size: 7))
                                if preferences.navigationStyle == .labels { Text(preferences.title(for: tab)).font(.system(size: 6.5, weight: .medium)).lineLimit(1) }
                            }.padding(.horizontal, 5).frame(maxWidth: .infinity).frame(height: 16)
                                .foregroundStyle(tab == .home ? accent : Color.white.opacity(0.5))
                                .background(tab == .home ? accent.opacity(0.12) : .clear, in: Capsule())
                        }
                    }
                    LayoutArt(layout: preferences.dashboardLayout, detailed: true)
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
                .frame(width: openSize.width, height: openSize.height - 18)
                .opacity(open ? 1 : 0).scaleEffect(open ? 1 : 0.9, anchor: .top)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: open ? 16 : 8, bottomTrailingRadius: open ? 16 : 8))
            .animation(spring, value: open)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: preferences.panelSize)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: preferences.compactStyle)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: preferences.hiddenTabs)
            Label(open ? "Clique pour replier" : "Clique pour déplier", systemImage: "hand.tap")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10).frame(height: 22).background(.black.opacity(0.35), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
        }
        .frame(height: 196).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture { replay?.cancel(); open.toggle(); Haptics.play(open ? .levelChange : .alignment) }
        .onChange(of: preferences.motionStyle) { _, _ in demonstrate() }
        .onChange(of: preferences.compactStyle) { _, _ in if open { demonstrate(reopen: false) } }
        .onDisappear { replay?.cancel() }
        .accessibilityElement(children: .ignore).accessibilityLabel("Aperçu du notch").accessibilityAddTraits(.isButton)
    }
    /// Folds then unfolds, so a newly chosen animation or closed style is seen immediately.
    private func demonstrate(reopen: Bool = true) {
        replay?.cancel()
        open = false
        replay = Task {
            do {
                try await Task.sleep(for: .milliseconds(reopen ? 480 : 1100))
                open = true
            } catch {}
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A choice shown as a picture first, a word second.
private struct OptionTile<Art: View>: View {
    @Environment(\.notcherAccent) private var accent
    let title: String
    let selected: Bool
    var action: () -> Void
    @ViewBuilder var art: Art
    @State private var hovering = false
    var body: some View {
        Button { if !selected { action(); Haptics.play(.alignment) } else { action() } } label: {
            VStack(spacing: 9) {
                art.frame(maxWidth: .infinity).frame(height: 58)
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 10))
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }.foregroundStyle(selected ? accent : Color.white.opacity(0.6))
            }
            .padding(.horizontal, 8).padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(selected ? accent.opacity(0.07) : hovering ? Theme.raised : Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? accent.opacity(0.9) : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: selected)
            .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Illustrations

private struct LayoutArt: View {
    @Environment(\.notcherAccent) private var accent
    let layout: DashboardLayout
    var detailed = false
    private func block(_ strength: Double = 0.22) -> some View { RoundedRectangle(cornerRadius: detailed ? 6 : 4).fill(accent.opacity(strength)) }
    var body: some View {
        let gap: CGFloat = detailed ? 5 : 3
        switch layout {
        case .overview:
            GeometryReader { geo in
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        block(0.30).overlay { Image(systemName: "music.note").font(.system(size: detailed ? 11 : 8)).foregroundStyle(accent) }
                        block().frame(width: geo.size.width * 0.27).overlay { Circle().stroke(accent, lineWidth: 1.5).padding(detailed ? 8 : 4) }
                    }.frame(height: (geo.size.height - gap) * 0.64)
                    HStack(spacing: gap) {
                        block(0.16)
                        block(0.16).frame(width: geo.size.width * 0.36)
                    }
                }
            }
        case .media:
            GeometryReader { geo in
                VStack(spacing: gap) {
                    block(0.30).overlay { Image(systemName: "music.note").font(.system(size: detailed ? 14 : 10)).foregroundStyle(accent) }
                        .frame(height: (geo.size.height - gap) * 0.70)
                    block(0.16).overlay { Capsule().fill(accent.opacity(0.7)).frame(height: 2).padding(.horizontal, detailed ? 14 : 8) }
                }
            }
        case .pomodoro:
            HStack(spacing: gap) {
                block(0.30).overlay { Circle().trim(from: 0, to: 0.7).stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)).padding(detailed ? 12 : 6) }
                    .aspectRatio(detailed ? 0.9 : 0.8, contentMode: .fit)
                block(0.16).overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: detailed ? 6 : 4) {
                        ForEach([0.8, 0.55, 0.7], id: \.self) { width in
                            HStack(spacing: 3) { Circle().frame(width: 3, height: 3); Capsule().frame(width: (detailed ? 70 : 34) * width, height: 2) }
                        }
                    }.foregroundStyle(accent.opacity(0.75)).padding(detailed ? 10 : 6)
                }
            }
        }
    }
}

/// Small desktop with a black notch hanging from its top edge.
private struct MiniScreen<Content: View>: View {
    let notch: CGSize
    var radius: CGFloat = 7
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.10))
            content.frame(width: notch.width, height: notch.height)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
        }.frame(width: 108, height: 58).clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
private struct SizeArt: View {
    @Environment(\.notcherAccent) private var accent
    let size: PanelSize
    var body: some View {
        MiniScreen(notch: size == .compact ? CGSize(width: 64, height: 34) : CGSize(width: 86, height: 46)) {
            RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.3)).padding(.horizontal, 7).padding(.top, 9).padding(.bottom, 6)
        }
    }
}
private struct NavigationArt: View {
    @Environment(\.notcherAccent) private var accent
    let style: NavigationStyle
    var body: some View {
        HStack(spacing: style == .labels ? 3 : 6) {
            ForEach(0..<(style == .labels ? 3 : 4), id: \.self) { index in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 6, height: 6)
                    if style == .labels { Capsule().frame(width: 13, height: 3) }
                }
                .padding(.horizontal, 5).frame(height: 18)
                .foregroundStyle(index == 0 ? accent : Color.white.opacity(0.45))
                .background(index == 0 ? accent.opacity(0.14) : .clear, in: Capsule())
            }
        }.padding(.horizontal, 6).frame(height: 28).background(.black, in: RoundedRectangle(cornerRadius: 9))
    }
}
private struct CompactArt: View {
    let style: CompactStyle
    var body: some View {
        MiniScreen(notch: CGSize(width: style == .info ? 92 : 44, height: 15), radius: 6) {
            HStack {
                if style == .info { Capsule().frame(width: 15, height: 3) }
                Spacer(minLength: 36)
                if style == .info { Capsule().frame(width: 12, height: 3) }
            }.foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 7)
        }
    }
}
/// The notch as the pointer meets it: opening by itself, waiting for a click, or untouched.
private struct OpenModeArt: View {
    @Environment(\.notcherAccent) private var accent
    let mode: OpenMode
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.10))
            UnevenRoundedRectangle(bottomLeadingRadius: mode == .hover ? 9 : 6, bottomTrailingRadius: mode == .hover ? 9 : 6).fill(.black)
                .frame(width: mode == .hover ? 84 : mode == .touch ? 60 : 52, height: mode == .hover ? 38 : mode == .touch ? 16 : 13)
                .overlay { if mode == .touch { UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).strokeBorder(accent.opacity(0.9), lineWidth: 1) } }
            Image(systemName: mode == .hover ? "cursorarrow" : mode == .touch ? "cursorarrow.rays" : "cursorarrow.click")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(mode == .hover ? Color.white : accent)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(x: 14, y: mode == .hover ? 30 : 20)
        }.frame(width: 128, height: 58).clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
private struct MotionArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: MotionStyle
    let trigger: Int
    @State private var open = false
    @State private var run: Task<Void, Never>?
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.10))
            UnevenRoundedRectangle(bottomLeadingRadius: open ? 9 : 5, bottomTrailingRadius: open ? 9 : 5).fill(.black)
                .frame(width: open ? 70 : 34, height: open ? 40 : 11)
        }
        .frame(width: 84, height: 58).clipShape(RoundedRectangle(cornerRadius: 7))
        .onChange(of: trigger) { _, _ in play() }
        .onDisappear { run?.cancel() }
    }
    private func play() {
        guard !reduceMotion else { return }
        run?.cancel()
        withAnimation(.spring(response: style.opening.response, dampingFraction: style.opening.damping)) { open = true }
        run = Task {
            do {
                try await Task.sleep(for: .milliseconds(900))
                withAnimation(.spring(response: style.closing.response, dampingFraction: style.closing.damping)) { open = false }
            } catch {}
        }
    }
}

// MARK: - Comportement et services

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}
private struct SettingRow<Control: View>: View {
    @Environment(\.notcherAccent) private var accent
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var divider = true
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(accent)
                    .frame(width: 30, height: 30).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 14)
                control
            }.padding(.horizontal, 14).padding(.vertical, 12)
            if divider { Divider().overlay(Theme.border).padding(.leading, 57) }
        }
    }
}
private struct Switch: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View { Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title) }
}

private struct BehaviorPane: View {
    @ObservedObject var preferences: Preferences
    @Binding var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "Ouverture et fermeture") {
                HStack(spacing: 10) {
                    ForEach(OpenMode.allCases) { mode in
                        OptionTile(title: mode.title, selected: preferences.openMode == mode) { preferences.openMode = mode } art: { OpenModeArt(mode: mode) }
                    }
                }
                Text(preferences.openMode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 2)
                SettingsCard {
                    SettingRow(symbol: "timer", title: "Fermeture automatique", subtitle: "Temps d’attente une fois le pointeur sorti du panneau.") {
                        Picker("Fermeture automatique", selection: $preferences.closeDelay) {
                            ForEach(CloseDelay.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    }
                    SettingRow(symbol: "keyboard", title: "Raccourci clavier", subtitle: "Ouvre ou referme le panneau depuis n’importe quelle app.", divider: false) {
                        HStack(spacing: 4) {
                            ForEach(["⌘", "⇧", "Espace"], id: \.self) { key in
                                Text(key).font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).frame(height: 24)
                                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                            }
                        }
                    }
                }
            }
            SettingsGroup(title: "Sensations") {
                SettingsCard {
                    SettingRow(symbol: "hand.tap", title: "Retour haptique", subtitle: "Légère vibration du trackpad à l’ouverture, à la fermeture et aux changements d’onglet.") {
                        Switch(title: "Retour haptique", isOn: Binding(get: { preferences.haptics }, set: { value in
                            preferences.haptics = value
                            if value { Haptics.enabled = true; Haptics.play(.levelChange) }
                        }))
                    }
                    SettingRow(symbol: "speaker.wave.2", title: "Indicateurs dans le notch", subtitle: "Niveau du volume à chaque appui, et batterie au branchement du chargeur.", divider: false) {
                        Switch(title: "Indicateurs dans le notch", isOn: $preferences.showHUD)
                    }
                }
            }
            SettingsGroup(title: "Mac") {
                SettingsCard {
                    SettingRow(symbol: "display", title: "Écran", subtitle: "Automatique choisit l’écran qui possède une encoche.") {
                        Picker("Écran", selection: $preferences.screenID) {
                            Text("Automatique").tag(0)
                            ForEach(screens, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 230)
                    }
                    SettingRow(symbol: "power", title: "Ouvrir à la connexion", subtitle: "Notcher démarre avec ta session.", divider: false) {
                        Switch(title: "Ouvrir à la connexion", isOn: Binding(get: { preferences.launchAtLogin }, set: { value in
                            do { try preferences.setLogin(value); error = nil } catch let failure { error = failure.localizedDescription }
                        }))
                    }
                }
            }
        }
    }
    /// Two identical monitors share a name; the display number keeps every entry distinct.
    private var screens: [(id: Int, name: String)] {
        var seen = Set<Int>()
        return NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue, id != 0, seen.insert(id).inserted else { return nil }
            return (id, screen.localizedName)
        }
    }
}

private struct ServicesPane: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var preferences: Preferences
    @ObservedObject var agents: AgentService
    @Binding var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "Dans le notch") {
                SettingsCard {
                    SettingRow(symbol: "music.note", title: "Lecture en cours", subtitle: "Morceau, pochette et commandes de Spotify, Music et des autres lecteurs.") {
                        Switch(title: "Lecture en cours", isOn: $preferences.mediaEnabled)
                    }
                    SettingRow(symbol: "moon.zzz", title: "Libérer le notch après une pause", subtitle: "Quand la lecture est en pause depuis ce délai, le notch fermé retrouve la date et l’heure. Le morceau reste dans le panneau.") {
                        Picker("Libérer le notch après une pause", selection: $preferences.mediaRestMinutes) {
                            ForEach(MediaRest.choices, id: \.self) { Text(MediaRest.title(minutes: $0)).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    SettingRow(symbol: "text.bubble", title: "Annoncer le morceau", subtitle: "Affiche brièvement le titre dans le notch fermé quand la chanson change.") {
                        Switch(title: "Annoncer le morceau", isOn: $preferences.announceTrack)
                    }
                    SettingRow(symbol: "doc.on.clipboard", title: "Historique du presse-papiers", subtitle: "Les 30 derniers textes copiés, gardés en mémoire seulement. Désactiver efface l’historique.", divider: false) {
                        Switch(title: "Historique du presse-papiers", isOn: $preferences.clipboardEnabled)
                    }
                }
            }
            SettingsGroup(title: "Dépôt de fichiers") {
                SettingsCard {
                    SettingRow(symbol: "clock.arrow.circlepath", title: "Conserver les copies", subtitle: "Les fichiers épinglés restent ; tes originaux ne sont jamais touchés.") {
                        Picker("Conservation", selection: $preferences.retentionHours) {
                            Text("1 h").tag(1); Text("24 h").tag(24); Text("7 jours").tag(168); Text("Toujours").tag(0)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                    }
                    SettingRow(symbol: "folder", title: "Données de Notcher", subtitle: "Notes, dépôt et relevés, stockés uniquement sur ce Mac.", divider: false) {
                        CapsuleButton(title: "Afficher", symbol: "arrow.up.forward") { NSWorkspace.shared.open(AppPaths.support) }
                    }
                }
            }
            SettingsGroup(title: "Agents") {
                SettingsCard {
                    SettingRow(symbol: "sparkles", title: "Claude Code", subtitle: agents.claudeStatus) {
                        HStack(spacing: 8) {
                            Button { if let url = URL(string: "https://code.claude.com/docs/en/statusline") { NSWorkspace.shared.open(url) } } label: {
                                Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Documentation de la barre d’état de Claude Code")
                            CapsuleButton(title: agents.claudeInstalled ? "Déconnecter" : "Connecter", symbol: agents.claudeInstalled ? "xmark" : "link", primary: !agents.claudeInstalled) {
                                do { if agents.claudeInstalled { try agents.uninstallClaude() } else { try agents.installClaude() }; error = nil }
                                catch let failure { error = failure.localizedDescription }
                            }.help("Installe ou retire le relais dans la barre d’état de Claude Code, en préservant la commande existante.")
                        }
                    }
                    SettingRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Codex", subtitle: agents.codexStatus) {
                        Switch(title: "Codex", isOn: Binding(get: { preferences.codexEnabled }, set: { enabled in
                            preferences.codexEnabled = enabled
                            if enabled { Task { await agents.refreshCodex() } } else { agents.disconnectCodex() }
                        }))
                    }
                    SettingRow(symbol: "terminal", title: "Chemin du CLI Codex", subtitle: "Laisse vide pour une détection automatique.", divider: false) {
                        TextField("Automatique", text: $preferences.codexPath).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 9).frame(width: 230, height: 26)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    }
                }
            }
        }
    }
}

// MARK: - Widgets

/// Composes the overview: drag to move, resize, remove, add, and choose which row is the tall one.
private struct WidgetsPane: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var preferences: Preferences
    @State private var target: String?
    @State private var notice: String?
    private var layout: HomeLayout { preferences.homeLayout }
    private let canvas = CGSize(width: 664, height: 250)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if preferences.dashboardLayout != .overview {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle").foregroundStyle(accent)
                    Text("L’aperçu utilise la disposition « \(preferences.dashboardLayout.title) ». Les widgets s’affichent avec la disposition « Complet ».").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    CapsuleButton(title: "Utiliser Complet", primary: true) { preferences.dashboardLayout = .overview }
                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            }
            SettingsGroup(title: "Ton aperçu", hint: "Glisse un widget pour le déplacer") {
                board
                Text(notice ?? "Chaque rangée accepte jusqu’à trois widgets. Un widget large prend deux fois la place d’un étroit, et son contenu s’adapte à sa taille.")
                    .font(.system(size: 11)).foregroundStyle(notice == nil ? Color.secondary : Theme.orange).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup(title: "Ajouter", hint: layout.available.isEmpty ? "Tous les widgets sont déjà sur l’aperçu" : "Clique, ou glisse vers une rangée") {
                FlowRow(spacing: 8) {
                    ForEach(layout.available) { widget in
                        Button { change { if !$0.add(widget) { notice = "Les deux rangées sont pleines : retire d’abord un widget." } } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: widget.symbol).font(.system(size: 11))
                                Text(widget.title).font(.system(size: 11, weight: .medium))
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).opacity(0.7)
                            }
                            .padding(.horizontal, 11).frame(height: 30).foregroundStyle(.white.opacity(0.85))
                            .background(Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border)).contentShape(Capsule())
                        }.buttonStyle(PressStyle(scale: 0.96)).draggable(widget.rawValue)
                            .accessibilityLabel("Ajouter \(widget.title)")
                    }
                }
            }
            SettingsGroup(title: "Hauteur des rangées") {
                HStack(spacing: 10) {
                    ForEach(RowBalance.allCases) { balance in
                        OptionTile(title: balance.title, selected: layout.balance == balance) { change { $0.balance = balance } } art: { BalanceArt(balance: balance) }
                    }
                }.disabled(layout.rows[1].isEmpty).opacity(layout.rows[1].isEmpty ? 0.45 : 1)
            }
            renamedTabs
            HStack {
                Spacer()
                CapsuleButton(title: "Aperçu d’origine", symbol: "arrow.counterclockwise") { change { $0 = .standard } }
                    .disabled(layout == .standard)
            }
        }
    }
    private func change(_ edit: (inout HomeLayout) -> Void) {
        var copy = preferences.homeLayout
        notice = nil
        edit(&copy)
        guard copy != preferences.homeLayout else { return }
        withAnimation(.snappy(duration: 0.28)) { preferences.homeLayout = copy }
        Haptics.play(.alignment)
    }
    private var board: some View {
        // Same proportions as the real panel (320 pt of page), scaled to the miniature.
        let scale = (canvas.height - 24) / 320
        let heights = layout.heights(total: 320, spacing: 8 / scale).map { $0 * scale }
        return VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                let free = layout.hasRoom(in: row)
                // The landing strip at the end of a row takes its width from the tiles.
                let widths = layout.widths(row: row, total: canvas.width - 24 - (free && !layout.rows[row].isEmpty ? 44 : 0), spacing: 8)
                HStack(spacing: 8) {
                    ForEach(Array(layout.rows[row].enumerated()), id: \.element.id) { index, tile in
                        cell(tile, row: row, index: index).frame(width: widths[index])
                    }
                    if free { landing(row: row, empty: layout.rows[row].isEmpty) }
                }.frame(height: layout.rows[row].isEmpty ? 40 : heights[row])
            }
        }
        .padding(12).frame(width: canvas.width)
        .background(.black, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
    }
    /// Free space at the end of a row: drop a widget here to append it.
    private func landing(row: Int, empty: Bool) -> some View {
        let id = "row-\(row)"
        return RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(target == id ? 0.9 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .background(accent.opacity(target == id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if empty { Text("Glisse un widget ici pour créer une seconde rangée").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                else { Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(accent.opacity(0.6)) }
            }
            .frame(maxWidth: empty ? .infinity : 36)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in drop(items, row: row, index: layout.rows[row].count) } isTargeted: { inside in target = inside ? id : (target == id ? nil : target) }
    }
    private func drop(_ items: [String], row: Int, index: Int) -> Bool {
        guard let key = items.first, let widget = HomeWidget(rawValue: key) else { return false }
        var done = false
        change { done = $0.place(widget, row: row, index: index); if !done { notice = "Cette rangée est pleine : retire d’abord un widget." } }
        return done
    }
    private func cell(_ tile: HomeTile, row: Int, index: Int) -> some View {
        let widget = tile.widget
        let active = target == widget.rawValue
        return ZStack {
            VStack(spacing: 4) {
                Image(systemName: widget.symbol).font(.system(size: 14))
                Text(widget.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }.foregroundStyle(accent).padding(.horizontal, 4)
            VStack {
                HStack(spacing: 4) {
                    control(tile.wide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", tile.wide ? "Rendre \(widget.title) étroit" : "Rendre \(widget.title) large") {
                        change { $0.setWide(widget, !tile.wide) }
                    }
                    Spacer(minLength: 0)
                    if layout.widgets.count > 1 { control("xmark", "Retirer \(widget.title)") { change { $0.remove(widget) } } }
                }
                Spacer(minLength: 0)
            }.padding(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(accent.opacity(active ? 0.28 : 0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(active ? 1 : 0.28), lineWidth: active ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .draggable(widget.rawValue) {
            Label(widget.title, systemImage: widget.symbol).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                .foregroundStyle(accent.contrastingText).background(accent, in: Capsule())
        }
        .dropDestination(for: String.self) { items, _ in drop(items, row: row, index: index) } isTargeted: { inside in target = inside ? widget.rawValue : (target == widget.rawValue ? nil : target) }
        .help("Glisser pour déplacer \(widget.title)")
        .accessibilityElement(children: .contain).accessibilityLabel("\(widget.title), rangée \(row + 1), \(tile.wide ? "large" : "étroit")")
    }
    private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 18).background(.black.opacity(0.55), in: Circle()).contentShape(Circle())
        }.buttonStyle(PressStyle(scale: 0.85)).help(help).accessibilityLabel(help)
    }
    /// Tabs whose content is now also a widget get a name that says what only they still offer.
    @ViewBuilder private var renamedTabs: some View {
        let renamed = NotchTab.allCases.filter { preferences.title(for: $0) != $0.rawValue }
        if !renamed.isEmpty {
            SettingsGroup(title: "Onglets concernés") {
                SettingsCard {
                    ForEach(Array(renamed.enumerated()), id: \.element.id) { index, tab in
                        let hidden = preferences.hiddenTabs.contains(tab.key)
                        SettingRow(symbol: tab.symbol, title: "« \(tab.rawValue) » devient « \(preferences.title(for: tab)) »",
                                   subtitle: "Le widget est sur l’aperçu ; l’onglet garde la vue complète. Tu peux aussi le masquer.", divider: index < renamed.count - 1) {
                            CapsuleButton(title: hidden ? "Afficher l’onglet" : "Masquer l’onglet", symbol: hidden ? "eye" : "eye.slash") {
                                if hidden { preferences.hiddenTabs.remove(tab.key) } else { preferences.hiddenTabs.insert(tab.key) }
                            }
                        }
                    }
                }
            }
        }
    }
}
private struct BalanceArt: View {
    @Environment(\.notcherAccent) private var accent
    let balance: RowBalance
    var body: some View {
        let top: CGFloat = balance == .top ? 30 : balance == .even ? 22 : 14
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.3)).frame(height: top)
            RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.3)).frame(height: 44 - top)
        }.frame(width: 96)
    }
}
/// Left-aligned chips that wrap onto as many lines as needed.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

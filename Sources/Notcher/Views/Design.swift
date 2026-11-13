import SwiftUI
import NotcherCore

enum Theme {
    static let accent = Color(red: 0.70, green: 0.93, blue: 0.66)
    static let surface = Color(white: 0.075)
    static let raised = Color(white: 0.11)
    static let muted = Color(white: 0.50)
    static let border = Color.white.opacity(0.07)
    static let orange = Color(red: 0.92, green: 0.61, blue: 0.39)
}

private struct NotcherAccentKey: EnvironmentKey {
    static let defaultValue = Theme.accent
}
private struct NotcherPanelActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var notcherPanelActive: Bool {
        get { self[NotcherPanelActiveKey.self] }
        set { self[NotcherPanelActiveKey.self] = newValue }
    }
    var notcherAccent: Color {
        get { self[NotcherAccentKey.self] }
        set { self[NotcherAccentKey.self] = newValue }
    }
}

extension Color {
    var contrastingText: Color {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return .black }
        func linear(_ value: CGFloat) -> Double { let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance < 0.179 ? .white : .black
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Every control answers the pointer: it lightens under it and gives slightly when pressed.
struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    var size: CGFloat = 32
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint).frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
                .background(Color.white.opacity(hovering ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
            .buttonStyle(PressStyle()).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(L(help)).accessibilityLabel(L(help))
    }
}
struct CapsuleButton: View {
    @Environment(\.notcherAccent) private var accent
    let title: String
    var symbol: String? = nil
    var primary = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let symbol { Image(systemName: symbol).contentTransition(.symbolEffect(.replace)) }; Text(L(title)) }
                .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(primary ? accent.contrastingText : Color.white.opacity(0.85))
                .background(primary ? accent.opacity(hovering ? 0.88 : 1) : Color.white.opacity(hovering ? 0.13 : 0.075), in: Capsule())
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.96)).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View { Text(L(text)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
}
struct EmptyState: View {
    @Environment(\.notcherAccent) private var accent
    let symbol: String
    var title: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(accent).frame(height: 36)
            if !title.isEmpty { Text(L(title)).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct ErrorLine: View {
    let message: String?
    var body: some View { if let message { Label(L(message), systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.orange).lineLimit(3).textSelection(.enabled) } }
}

struct NotchShape: Shape {
    /// The outline leaves the top edge open: it sits on the screen border and must never show a line.
    var outline = false
    func path(in rect: CGRect) -> Path {
        let top: CGFloat = 12, bottom: CGFloat = min(27, rect.height / 2)
        var p = Path()
        if outline { p.move(to: CGPoint(x: rect.width, y: 0)) }
        else { p.move(to: .zero); p.addLine(to: CGPoint(x: rect.width, y: 0)) }
        p.addQuadCurve(to: CGPoint(x: rect.width - top, y: top), control: CGPoint(x: rect.width - top, y: 0))
        p.addLine(to: CGPoint(x: rect.width - top, y: rect.height - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.width - top - bottom, y: rect.height), control: CGPoint(x: rect.width - top, y: rect.height))
        p.addLine(to: CGPoint(x: top + bottom, y: rect.height))
        p.addQuadCurve(to: CGPoint(x: top, y: rect.height - bottom), control: CGPoint(x: top, y: rect.height))
        p.addLine(to: CGPoint(x: top, y: top)); p.addQuadCurve(to: .zero, control: CGPoint(x: top, y: 0))
        if !outline { p.closeSubpath() }
        return p
    }
}

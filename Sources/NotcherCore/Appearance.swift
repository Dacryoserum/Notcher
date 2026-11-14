import Foundation
import CoreGraphics

public enum DashboardLayout: String, CaseIterable, Identifiable {
    case overview, media, pomodoro
    public var id: String { rawValue }
    public var title: String { switch self { case .overview: return L("Complet"); case .media: return L("Médias"); case .pomodoro: return L("Pomodoro") } }
}
public enum PanelSize: String, CaseIterable, Identifiable {
    case compact, comfortable
    public var id: String { rawValue }
    public var title: String { self == .compact ? L("Compact") : L("Spacieux") }
    public var width: CGFloat { self == .compact ? 690 : 790 }
    public var pageHeight: CGFloat { self == .compact ? 320 : 380 }
}
public enum NavigationStyle: String, CaseIterable, Identifiable {
    case labels, icons
    public var id: String { rawValue }
    public var title: String { self == .labels ? L("Icônes et texte") : L("Icônes") }
}
public struct AccentColor: Equatable {
    public static let `default` = AccentColor(hex: "B3EDA8")!
    public let hex: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, value.allSatisfy(\.isHexDigit), let number = UInt32(value, radix: 16) else { return nil }
        self.hex = value.uppercased()
        red = Double((number >> 16) & 255) / 255; green = Double((number >> 8) & 255) / 255; blue = Double(number & 255) / 255
    }
}
/// Feel of the unfold animation. The spring values are consumed by the interface layer.
public enum MotionStyle: String, CaseIterable, Identifiable, Sendable {
    case smooth, snappy, bouncy
    public var id: String { rawValue }
    public var title: String { switch self { case .smooth: return L("Fluide"); case .snappy: return L("Vive"); case .bouncy: return L("Rebond") } }
    /// Spring used when the panel unfolds.
    public var opening: (response: Double, damping: Double) {
        switch self { case .smooth: return (0.42, 0.86); case .snappy: return (0.28, 0.92); case .bouncy: return (0.46, 0.66) }
    }
    /// Spring used when the panel folds back or only its closed width changes; never bouncy enough to flicker.
    public var closing: (response: Double, damping: Double) {
        switch self { case .smooth: return (0.36, 1.0); case .snappy: return (0.24, 1.0); case .bouncy: return (0.38, 0.84) }
    }
}
/// What it takes to unfold the panel.
public enum OpenMode: String, CaseIterable, Identifiable, Sendable {
    /// `touch` sits between the two: hovering is acknowledged, a click opens.
    case hover, touch, click
    public var id: String { rawValue }
    public var title: String { switch self { case .hover: return L("Au survol"); case .touch: return L("Survol puis clic"); case .click: return L("Au clic") } }
    public var detail: String {
        switch self {
        case .hover: return L("Le panneau s’ouvre dès que le pointeur arrive sur le notch.")
        case .touch: return L("Le notch réagit au survol (vibration, léger agrandissement) et s’ouvre au clic.")
        case .click: return L("Rien ne bouge au survol ; un clic sur le notch ouvre le panneau.")
        }
    }
}
/// A paused player stops occupying the closed notch after this long.
public enum MediaRest {
    public static let choices = [1, 5, 15, 60, 0]
    public static func title(minutes: Int) -> String { minutes == 0 ? L("Jamais") : minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min" }
    public static func isResting(pausedFor seconds: Double, limitMinutes: Int) -> Bool {
        limitMinutes > 0 && seconds.isFinite && seconds >= Double(limitMinutes) * 60
    }
}
/// How long the panel waits after the pointer leaves before folding back.
public enum CloseDelay: String, CaseIterable, Identifiable, Sendable {
    case fast, normal, slow
    public var id: String { rawValue }
    public var title: String { switch self { case .fast: return L("Rapide"); case .normal: return L("Normale"); case .slow: return L("Lente") } }
    public var seconds: Double { switch self { case .fast: return 0.3; case .normal: return 0.7; case .slow: return 1.5 } }
}
/// What the closed notch shows when nothing is playing.
public enum CompactStyle: String, CaseIterable, Identifiable, Sendable {
    case info, minimal
    public var id: String { rawValue }
    public var title: String { self == .info ? L("Date et heure") : L("Discret") }
}
/// The panel always hangs from the top centre of its screen; only the lower edge and the sides move.
public enum PanelGeometry {
    public static func frame(size: CGSize, topCenter: CGPoint) -> CGRect {
        CGRect(x: topCenter.x - size.width / 2, y: topCenter.y - size.height, width: size.width, height: size.height)
    }
    /// Window size able to hold a transition between two shapes, with room for a spring overshoot.
    /// Widths stay even so the centred content never lands on a half point.
    public static func envelope(_ first: CGSize, _ second: CGSize, margin: CGFloat = 0) -> CGSize {
        func clean(_ value: CGFloat) -> CGFloat { value.isFinite ? max(1, value) : 1 }
        let width = (max(clean(first.width), clean(second.width)) + margin * 2).rounded(.up)
        let height = (max(clean(first.height), clean(second.height)) + margin).rounded(.up)
        return CGSize(width: width + width.truncatingRemainder(dividingBy: 2), height: height)
    }
}
public enum PanelDismissal {
    public static func shouldClose(pointerInside: Bool, pinned: Bool, dragging: Bool, dialogOpen: Bool, editingText: Bool) -> Bool {
        !pointerInside && !pinned && !dragging && !dialogOpen && !editingText
    }
}

/// Closed panels occupy only the menu-bar band, with symmetrical wings around the camera.
public enum CompactPanel {
    public static func size(notchWidth: CGFloat, notchHeight: CGFloat, media: Bool, focus: Bool, activity: Bool, idleInfo: Bool = true, ambient: Bool = false, hovered: Bool = false) -> CGSize {
        // `ambient`: a state or an event shown with pictures only, which needs less room than a titled activity.
        let wing: CGFloat = activity ? 126 : (media || focus) ? 92 : (idleInfo || ambient) ? 72 : 14
        // A hovered notch swells a little to show it is ready for a click.
        return CGSize(width: notchWidth + wing * 2 + (hovered ? 14 : 0), height: notchHeight + (hovered ? 4 : 0))
    }
}

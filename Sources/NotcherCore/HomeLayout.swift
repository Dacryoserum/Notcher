import Foundation
import CoreGraphics

/// Everything that can be placed on the overview.
public enum HomeWidget: String, CaseIterable, Identifiable, Codable, Sendable {
    case media, focus, volume, agenda, note, clipboard, files, battery, agents, clock, awake
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .media: return L("Médias")
        case .focus: return L("Pomodoro")
        case .volume: return L("Volume")
        case .agenda: return L("Agenda")
        case .note: return L("Texte")
        case .clipboard: return L("Presse-papiers")
        case .files: return L("Dépôt")
        case .battery: return L("Batterie")
        case .agents: return L("Quotas")
        case .clock: return L("Horloge")
        case .awake: return L("Éveil")
        }
    }
    public var symbol: String {
        switch self {
        case .media: return "music.note"
        case .focus: return "timer"
        case .volume: return "speaker.wave.2"
        case .agenda: return "calendar"
        case .note: return "text.alignleft"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "tray"
        case .battery: return "battery.75percent"
        case .agents: return "sparkles"
        case .clock: return "clock"
        case .awake: return "cup.and.saucer"
        }
    }
    /// Smallest footprint, in grid cells, at which the widget still shows something useful.
    public var minimum: (w: Int, h: Int) {
        switch self {
        case .agenda, .note, .clipboard, .agents: return (2, 1)
        default: return (1, 1)
        }
    }
    /// Footprint given to a widget that has just been added.
    public var preferred: (w: Int, h: Int) {
        switch self {
        case .media: return (4, 2)
        case .focus, .note, .clipboard, .agents: return (3, 2)
        case .agenda, .files: return (3, 1)
        case .volume, .battery, .clock, .awake: return (2, 1)
        }
    }
}

/// A widget and the cells it covers. `x`/`y` are the top-left cell, `w`/`h` the span.
public struct HomeItem: Codable, Equatable, Identifiable, Sendable {
    public var widget: HomeWidget
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    public var id: String { widget.rawValue }
    public init(_ widget: HomeWidget, x: Int, y: Int, w: Int, h: Int) { self.widget = widget; self.x = x; self.y = y; self.w = w; self.h = h }
    func overlaps(_ other: HomeItem) -> Bool { x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h }
    func contains(x cellX: Int, y cellY: Int) -> Bool { cellX >= x && cellX < x + w && cellY >= y && cellY < y + h }
}

/// The overview is a grid of cells. Every mutation leaves a layout that can be drawn: each widget
/// at most once, inside the grid, at least its minimum size, never overlapping, never empty.
public struct HomeLayout: Codable, Equatable, Sendable {
    public static let columns = 8
    public static let rows = 4
    public static let standard = HomeLayout(items: [
        HomeItem(.media, x: 0, y: 0, w: 5, h: 3), HomeItem(.focus, x: 5, y: 0, w: 3, h: 3),
        HomeItem(.volume, x: 0, y: 3, w: 5, h: 1), HomeItem(.agenda, x: 5, y: 3, w: 3, h: 1)
    ])
    public private(set) var items: [HomeItem]

    public init(items: [HomeItem]) { self.items = items; normalize() }

    private enum CodingKeys: String, CodingKey { case items, rows, balance }
    private struct LegacyTile: Decodable { let widget: HomeWidget; let wide: Bool }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([HomeItem].self, forKey: .items) { self.items = items }
        else {
            // Layout of the first 1.0 builds: two rows of narrow or wide tiles, one row taller than the other.
            let rows = try container.decode([[LegacyTile]].self, forKey: .rows).prefix(2).filter { !$0.isEmpty }
            let balance = (try? container.decode(String.self, forKey: .balance)) ?? "top"
            let heights = rows.count < 2 ? [Self.rows] : balance == "even" ? [2, 2] : balance == "bottom" ? [1, 3] : [3, 1]
            var converted: [HomeItem] = [], y = 0
            for (index, row) in rows.enumerated() {
                let weight = row.reduce(0) { $0 + ($1.wide ? 2 : 1) }
                var x = 0
                for (position, tile) in row.enumerated() {
                    let last = position == row.count - 1
                    let width = last ? Self.columns - x : max(1, Self.columns * (tile.wide ? 2 : 1) / weight)
                    converted.append(HomeItem(tile.widget, x: x, y: y, w: width, h: heights[index])); x += width
                }
                y += heights[index]
            }
            self.items = converted
        }
        normalize()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }
    /// Unreadable or outdated settings fall back to the standard overview instead of an empty page.
    public static func restore(_ data: Data?) -> HomeLayout {
        guard let data, let layout = try? JSONDecoder().decode(HomeLayout.self, from: data) else { return .standard }
        return layout
    }
    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public var widgets: [HomeWidget] { items.map(\.widget) }
    public var available: [HomeWidget] { HomeWidget.allCases.filter { !contains($0) } }
    public func contains(_ widget: HomeWidget) -> Bool { items.contains { $0.widget == widget } }
    public func item(_ widget: HomeWidget) -> HomeItem? { items.first { $0.widget == widget } }
    public func item(atX x: Int, y: Int) -> HomeItem? { items.first { $0.contains(x: x, y: y) } }

    private static func clamped(_ item: HomeItem) -> HomeItem {
        var copy = item
        let least = item.widget.minimum
        copy.w = min(columns, max(least.w, item.w)); copy.h = min(rows, max(least.h, item.h))
        copy.x = min(columns - copy.w, max(0, item.x)); copy.y = min(rows - copy.h, max(0, item.y))
        return copy
    }
    /// True when the item, once fitted inside the grid, touches no widget other than itself.
    public func isFree(_ candidate: HomeItem) -> Bool {
        let fitted = Self.clamped(candidate)
        return !items.contains { $0.widget != candidate.widget && $0.overlaps(fitted) }
    }
    /// Moves or resizes a widget. Refused, leaving the layout untouched, when the place is taken.
    @discardableResult public mutating func setFrame(_ widget: HomeWidget, x: Int, y: Int, w: Int, h: Int) -> Bool {
        guard let index = items.firstIndex(where: { $0.widget == widget }) else { return false }
        let fitted = Self.clamped(HomeItem(widget, x: x, y: y, w: w, h: h))
        guard isFree(fitted) else { return false }
        items[index] = fitted; return true
    }
    /// Moves a widget to a cell. Dropped on another widget, the two trade places when each fits the other's frame.
    @discardableResult public mutating func move(_ widget: HomeWidget, toX x: Int, y: Int) -> Bool {
        guard let source = item(widget) else { return false }
        if setFrame(widget, x: x, y: y, w: source.w, h: source.h) { return true }
        guard let other = item(atX: x, y: y), other.widget != widget,
              let first = items.firstIndex(where: { $0.widget == widget }), let second = items.firstIndex(where: { $0.widget == other.widget }) else { return false }
        let least = (widget.minimum, other.widget.minimum)
        guard other.w >= least.0.w, other.h >= least.0.h, source.w >= least.1.w, source.h >= least.1.h else { return false }
        items[first] = HomeItem(widget, x: other.x, y: other.y, w: other.w, h: other.h)
        items[second] = HomeItem(other.widget, x: source.x, y: source.y, w: source.w, h: source.h)
        return true
    }
    /// Adds a widget in the first free place, at its preferred size or, failing that, a smaller one.
    @discardableResult public mutating func add(_ widget: HomeWidget) -> Bool {
        guard !contains(widget) else { return false }
        let least = widget.minimum, wanted = widget.preferred
        var sizes: [(Int, Int)] = []
        for h in stride(from: wanted.h, through: least.h, by: -1) { for w in stride(from: wanted.w, through: least.w, by: -1) { sizes.append((w, h)) } }
        // Largest area first, so a widget only shrinks when it has to.
        for (w, h) in sizes.sorted(by: { $0.0 * $0.1 > $1.0 * $1.1 }) {
            for y in 0...(Self.rows - h) { for x in 0...(Self.columns - w) {
                let candidate = HomeItem(widget, x: x, y: y, w: w, h: h)
                if isFree(candidate) { items.append(candidate); return true }
            } }
        }
        return false
    }
    /// The last widget cannot be removed: an empty overview would look broken.
    @discardableResult public mutating func remove(_ widget: HomeWidget) -> Bool {
        guard items.count > 1, let index = items.firstIndex(where: { $0.widget == widget }) else { return false }
        items.remove(at: index); return true
    }
    private mutating func normalize() {
        var kept: [HomeItem] = []
        for item in items.map(Self.clamped) where !kept.contains(where: { $0.widget == item.widget || $0.overlaps(item) }) { kept.append(item) }
        items = kept.isEmpty ? Self.standard.items : kept
    }

    // MARK: Geometry

    public static func cellSize(in size: CGSize, spacing: CGFloat) -> CGSize {
        CGSize(width: max(1, (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)),
               height: max(1, (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)))
    }
    /// Rectangle of an item inside an area of `size`, with `spacing` between cells.
    public static func frame(of item: HomeItem, in size: CGSize, spacing: CGFloat) -> CGRect {
        let cell = cellSize(in: size, spacing: spacing)
        return CGRect(x: CGFloat(item.x) * (cell.width + spacing), y: CGFloat(item.y) * (cell.height + spacing),
                      width: CGFloat(item.w) * cell.width + CGFloat(item.w - 1) * spacing,
                      height: CGFloat(item.h) * cell.height + CGFloat(item.h - 1) * spacing)
    }
}

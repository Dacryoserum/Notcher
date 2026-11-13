import Foundation
import CoreGraphics

/// Everything that can be placed on the overview.
public enum HomeWidget: String, CaseIterable, Identifiable, Codable, Sendable {
    case media, focus, volume, agenda, note, clipboard, files, battery, agents, clock
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
        }
    }
}

public struct HomeTile: Codable, Equatable, Identifiable, Sendable {
    public var widget: HomeWidget
    /// A wide tile takes twice the width of a narrow one in its row.
    public var wide: Bool
    public var id: String { widget.rawValue }
    public var weight: Int { wide ? 2 : 1 }
    public init(_ widget: HomeWidget, wide: Bool = false) { self.widget = widget; self.wide = wide }
}

/// Which of the two rows is the tall one.
public enum RowBalance: String, CaseIterable, Identifiable, Codable, Sendable {
    case top, even, bottom
    public var id: String { rawValue }
    public var title: String { switch self { case .top: return L("Haut plus grand"); case .even: return L("Égales"); case .bottom: return L("Bas plus grand") } }
}

/// Two rows of tiles. Every mutation leaves a layout that can be drawn: no duplicate, no overfull row,
/// never an empty overview, and an empty row is always the lower one.
public struct HomeLayout: Codable, Equatable, Sendable {
    public static let maxTiles = 3
    /// A row holds at most this much width weight, so the narrowest tile keeps a usable width.
    public static let maxWeight = 4
    public static let standard = HomeLayout(rows: [[HomeTile(.media, wide: true), HomeTile(.focus)], [HomeTile(.volume, wide: true), HomeTile(.agenda)]], balance: .top)
    public private(set) var rows: [[HomeTile]]
    public var balance: RowBalance

    public init(rows: [[HomeTile]], balance: RowBalance = .top) {
        self.rows = rows; self.balance = balance
        normalize()
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([[HomeTile]].self, forKey: .rows)
        balance = (try? container.decode(RowBalance.self, forKey: .balance)) ?? .top
        normalize()
    }
    /// Unreadable or outdated settings fall back to the standard overview instead of an empty page.
    public static func restore(_ data: Data?) -> HomeLayout {
        guard let data, let layout = try? JSONDecoder().decode(HomeLayout.self, from: data) else { return .standard }
        return layout
    }
    /// The four fixed slots of the first 1.0 builds: large, narrow, large, narrow.
    public static func migrating(slots keys: [String]) -> HomeLayout? {
        let values = keys.compactMap(HomeWidget.init(rawValue:))
        guard values.count == 4, Set(values).count == 4 else { return nil }
        return HomeLayout(rows: [[HomeTile(values[0], wide: true), HomeTile(values[1])], [HomeTile(values[2], wide: true), HomeTile(values[3])]])
    }
    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public var widgets: [HomeWidget] { rows.flatMap { $0.map(\.widget) } }
    public var available: [HomeWidget] { HomeWidget.allCases.filter { !widgets.contains($0) } }
    public func contains(_ widget: HomeWidget) -> Bool { widgets.contains(widget) }
    public func position(of widget: HomeWidget) -> (row: Int, index: Int)? {
        for (row, tiles) in rows.enumerated() { if let index = tiles.firstIndex(where: { $0.widget == widget }) { return (row, index) } }
        return nil
    }
    public func hasRoom(in row: Int) -> Bool { rows.indices.contains(row) && rows[row].count < Self.maxTiles }

    /// Adds to the row with the most room. False when both rows are full or the widget is already there.
    @discardableResult public mutating func add(_ widget: HomeWidget) -> Bool {
        guard !contains(widget) else { return false }
        let row = rows[1].count < rows[0].count ? 1 : 0
        guard let target = [row, 1 - row].first(where: hasRoom) else { return false }
        return place(widget, row: target, index: rows[target].count)
    }
    /// The last widget cannot be removed: an empty overview would look broken.
    @discardableResult public mutating func remove(_ widget: HomeWidget) -> Bool {
        guard widgets.count > 1, let spot = position(of: widget) else { return false }
        rows[spot.row].remove(at: spot.index); normalize(); return true
    }
    /// Moves or inserts a widget. Dropped on a tile of a full row, it trades places with that tile.
    @discardableResult public mutating func place(_ widget: HomeWidget, row: Int, index: Int) -> Bool {
        guard rows.indices.contains(row), index >= 0 else { return false }
        let source = position(of: widget)
        if source?.row != row, rows[row].count >= Self.maxTiles {
            guard let source, index < rows[row].count else { return false }
            let displaced = rows[row][index]
            rows[row][index] = rows[source.row][source.index]
            rows[source.row][source.index] = displaced
            normalize(); return true
        }
        let tile = source.map { rows[$0.row].remove(at: $0.index) } ?? HomeTile(widget)
        rows[row].insert(tile, at: min(index, rows[row].count))
        normalize(); return true
    }
    /// Widening a tile narrows its neighbours when the row would otherwise overflow.
    public mutating func setWide(_ widget: HomeWidget, _ wide: Bool) {
        guard let spot = position(of: widget) else { return }
        rows[spot.row][spot.index].wide = wide
        fit(row: spot.row, keeping: wide ? widget : nil)
    }
    public func isWide(_ widget: HomeWidget) -> Bool { position(of: widget).map { rows[$0.row][$0.index].wide } ?? false }

    private mutating func fit(row: Int, keeping: HomeWidget? = nil) {
        while rows[row].reduce(0, { $0 + $1.weight }) > Self.maxWeight,
              let index = rows[row].lastIndex(where: { $0.wide && $0.widget != keeping }) ?? rows[row].lastIndex(where: \.wide) {
            rows[row][index].wide = false
        }
    }
    private mutating func normalize() {
        var seen = Set<HomeWidget>()
        var clean = rows.prefix(2).map { tiles in Array(tiles.filter { seen.insert($0.widget).inserted }.prefix(Self.maxTiles)) }
        while clean.count < 2 { clean.append([]) }
        if clean[0].isEmpty { clean.swapAt(0, 1) }
        rows = clean
        if rows[0].isEmpty { rows = Self.standard.rows }
        for row in rows.indices { fit(row: row) }
    }

    // MARK: Geometry

    /// Heights of the two rows inside `total`. A single row takes everything.
    public func heights(total: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !rows[1].isEmpty else { return [max(0, total), 0] }
        let usable = max(0, total - spacing)
        let small = min(108, usable / 2)
        switch balance {
        case .top: return [usable - small, small]
        case .even: return [usable / 2, usable / 2]
        case .bottom: return [small, usable - small]
        }
    }
    /// Widths of the tiles of one row, proportional to their weight.
    public func widths(row: Int, total: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard rows.indices.contains(row), !rows[row].isEmpty else { return [] }
        let tiles = rows[row]
        let usable = max(0, total - spacing * CGFloat(tiles.count - 1))
        let weight = CGFloat(tiles.reduce(0) { $0 + $1.weight })
        return tiles.map { (usable * CGFloat($0.weight) / weight).rounded(.down) }
    }
}

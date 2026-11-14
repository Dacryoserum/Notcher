import Foundation

/// The global shortcut that opens the panel. Stored with the label of its key as it was typed, so the
/// settings show the key printed on the user's keyboard, whatever its layout.
public struct HotKeyCombo: Codable, Equatable, Sendable {
    /// Virtual key code (kVK_…).
    public var keyCode: UInt16
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    /// What the key is called: "K", "Espace", "F5"…
    public var key: String

    public init(keyCode: UInt16, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false, key: String) {
        self.keyCode = keyCode; self.command = command; self.option = option; self.control = control; self.shift = shift; self.key = key
    }

    /// ⌘⇧Espace.
    public static let standard = HotKeyCombo(keyCode: 49, command: true, shift: true, key: "Espace")

    /// Modifiers in the order macOS menus print them.
    public var symbols: [String] {
        var result: [String] = []
        if control { result.append("⌃") }
        if option { result.append("⌥") }
        if shift { result.append("⇧") }
        if command { result.append("⌘") }
        return result
    }
    /// Each part as a key cap: the modifiers, then the key, translated when it has a name.
    public var caps: [String] { symbols + [L(key)] }
    public var display: String { caps.joined() }

    /// Function keys work alone; any other key needs ⌘, ⌥ or ⌃, or typing it anywhere would open the panel.
    public var isUsable: Bool { Self.functionKeys[keyCode] != nil || command || option || control }

    /// A global shortcut takes the combination away from every app. Refused: ⌘ or ⌘⇧ with a character
    /// (⌘C, ⌘⇧N…, the menus of every app), ⌘ alone with any other key but F1…F20 (⌘←, ⌘⌫ edit text
    /// everywhere), and the combinations macOS keeps for itself.
    public var isReserved: Bool {
        let commandOnly = command && !option && !control
        let function = Self.functionKeys[keyCode] != nil
        let character = !function && Self.specialKeys[keyCode] == nil
        if commandOnly && character { return true }
        if commandOnly && !shift && !function { return true }
        return Self.systemCombos.contains { $0.keyCode == keyCode && $0.command == command && $0.option == option && $0.control == control && $0.shift == shift }
    }
    /// Spotlight, input sources, emoji, app switcher, screenshots, force quit.
    static let systemCombos: [HotKeyCombo] = [
        HotKeyCombo(keyCode: 49, command: true, key: "Espace"), HotKeyCombo(keyCode: 49, command: true, option: true, key: "Espace"),
        HotKeyCombo(keyCode: 49, control: true, key: "Espace"), HotKeyCombo(keyCode: 49, option: true, control: true, key: "Espace"),
        HotKeyCombo(keyCode: 49, command: true, control: true, key: "Espace"), HotKeyCombo(keyCode: 48, command: true, key: "⇥"),
        HotKeyCombo(keyCode: 48, command: true, shift: true, key: "⇥"), HotKeyCombo(keyCode: 53, command: true, option: true, key: "⎋"),
        HotKeyCombo(keyCode: 20, command: true, shift: true, key: "3"), HotKeyCombo(keyCode: 21, command: true, shift: true, key: "4"),
        HotKeyCombo(keyCode: 23, command: true, shift: true, key: "5"), HotKeyCombo(keyCode: 22, command: true, shift: true, key: "6")
    ]

    /// Carbon modifier mask for RegisterEventHotKey (cmdKey, shiftKey, optionKey, controlKey).
    public var carbonModifiers: UInt32 {
        (command ? 0x0100 : 0) | (shift ? 0x0200 : 0) | (option ? 0x0800 : 0) | (control ? 0x1000 : 0)
    }
    /// The character an NSMenuItem needs to show and answer this key; empty when it has none.
    public var keyEquivalent: String {
        if let code = Self.menuCharacters[keyCode], let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
        if let index = Self.functionKeys[keyCode].flatMap({ Int($0.dropFirst()) }), let scalar = Unicode.Scalar(0xF704 + index - 1) {
            return String(Character(scalar))
        }
        return key.count == 1 ? key.lowercased() : ""
    }
    /// AppKit's characters for keys without a printable one (NSBackspaceCharacter, NSDeleteFunctionKey…).
    static let menuCharacters: [UInt16: UInt32] = [
        49: 0x20, 36: 0x0D, 76: 0x03, 48: 0x09, 51: 0x08, 117: 0xF728, 53: 0x1B,
        123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700, 115: 0xF729, 119: 0xF72B, 116: 0xF72C, 121: 0xF72D
    ]

    /// Keys without a printable character, by key code.
    public static func name(forKeyCode code: UInt16) -> String? {
        if let function = functionKeys[code] { return function }
        return specialKeys[code]
    }
    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    static let specialKeys: [UInt16: String] = [
        49: "Espace", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
    ]

    public var encoded: Data? { try? JSONEncoder().encode(self) }
    public static func restore(_ data: Data?) -> HotKeyCombo {
        guard let data, let value = try? JSONDecoder().decode(HotKeyCombo.self, from: data), value.isUsable, !value.isReserved, !value.key.isEmpty else { return .standard }
        return value
    }
}

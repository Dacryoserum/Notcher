import AppKit
import NotcherCore

/// What macOS knows about a connected Bluetooth audio device.
struct AccessoryInfo: Equatable, Sendable {
    var productID: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var main: Int?
    /// One figure for the wing of the notch: the weaker earbud, or the single battery.
    var summary: Int? { [left, right].compactMap { $0 }.min() ?? main }
    /// Each battery on its own, for the line under the notch.
    var details: [String] {
        var parts: [String] = []
        if let left { parts.append(L("G %lld %%", left)) }
        if let right { parts.append(L("D %lld %%", right)) }
        if let caseLevel { parts.append(L("Boîtier %lld %%", caseLevel)) }
        return parts.count > 1 ? parts : []
    }
}

enum Accessory {
    /// Reads the Bluetooth report in a child process: slow (a second or two) but never on the interface thread.
    static func lookup(name: String) async -> AccessoryInfo? {
        guard let output = try? await Command.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 8), output.status == 0 else { return nil }
        return parse(output.data, name: name)
    }
    static func parse(_ data: Data, name: String) -> AccessoryInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = section["device_connected"] as? [[String: Any]] else { return nil }
        let devices = connected.flatMap { entry in entry.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } } }
        func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let match = devices.first(where: { same($0.0, name) }) ?? devices.first(where: { ($0.1["device_minorType"] as? String) == "Headphones" }) else { return nil }
        func percent(_ key: String) -> Int? {
            guard let text = match.1[key] as? String, let value = Int(text.filter(\.isNumber)), (0...100).contains(value) else { return nil }
            return value
        }
        let product = (match.1["device_productID"] as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        return AccessoryInfo(productID: product, left: percent("device_batteryLevelLeft"), right: percent("device_batteryLevelRight"),
                             caseLevel: percent("device_batteryLevelCase"), main: percent("device_batteryLevelMain"))
    }
    /// Apple's own rendering of each AirPods model, as shown in Bluetooth settings. The files belong to macOS;
    /// when one is missing the symbol is used instead.
    private static let artwork: [Int: String] = [
        0x2002: "B188-B288.png", 0x200F: "B188-B288.png", 0x2013: "B688.icns", 0x2019: "B768.icns", 0x201B: "B768.icns",
        0x200E: "B298.png", 0x2014: "B698.icns", 0x2024: "B698.icns", 0x2027: "B788.icns",
        0x200A: "B515-16-White.icns", 0x201F: "B515c-19-Stardust.icns"
    ]
    private static func file(productID: Int?, name: String) -> String? {
        if let productID, let known = artwork[productID] { return known }
        let lowered = name.lowercased()
        guard lowered.contains("airpods") else { return nil }
        return lowered.contains("max") ? "B515-16-White.icns" : lowered.contains("pro") ? "B698.icns" : "B768.icns"
    }
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func image(productID: Int?, name: String) -> NSImage? {
        guard let file = file(productID: productID, name: name) else { return nil }
        if let cached = cache[file] { return cached }
        let image = NSImage(contentsOfFile: "/System/Library/PrivateFrameworks/CoreBluetoothUI.framework/Versions/A/Resources/" + file)
        if let image { cache[file] = image }
        return image
    }
    static func symbol(productID: Int?, name: String) -> String {
        let file = file(productID: productID, name: name) ?? ""
        if file.hasPrefix("B515") { return "airpodsmax" }
        if file.hasPrefix("B298") || file.hasPrefix("B698") || file.hasPrefix("B788") { return "airpodspro" }
        if file.hasPrefix("B688") { return "airpods.gen3" }
        return file.isEmpty ? "headphones" : "airpods"
    }
}

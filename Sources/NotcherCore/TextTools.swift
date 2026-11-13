import Foundation

public enum TextOperation: String, CaseIterable, Identifiable {
    case prettyJSON = "Formater JSON", compactJSON = "Compacter JSON"
    case encodeBase64 = "Encoder Base64", decodeBase64 = "Décoder Base64"
    case encodeURL = "Encoder URL", decodeURL = "Décoder URL"
    case trim = "Nettoyer", sort = "Trier les lignes", unique = "Lignes uniques"
    public var id: String { rawValue }

    public func apply(to text: String) throws -> String {
        switch self {
        case .prettyJSON, .compactJSON:
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let options: JSONSerialization.WritingOptions = self == .prettyJSON ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed]
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: options), as: UTF8.self)
        case .encodeBase64: return Data(text.utf8).base64EncodedString()
        case .decodeBase64:
            guard let data = Data(base64Encoded: text.filter { !$0.isWhitespace }), let value = String(data: data, encoding: .utf8) else { throw TextError.invalidBase64 }
            return value
        case .encodeURL:
            return text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? text
        case .decodeURL:
            guard let value = text.removingPercentEncoding else { throw TextError.invalidURL }
            return value
        case .trim: return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .sort: return text.components(separatedBy: "\n").sorted().joined(separator: "\n")
        case .unique:
            var seen = Set<String>()
            return text.components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
    }
}

public enum TextError: LocalizedError {
    case invalidBase64, invalidURL
    public var errorDescription: String? {
        switch self {
        case .invalidBase64: return L("Ce texte n’est pas un Base64 UTF-8 valide.")
        case .invalidURL: return L("Cette URL contient un encodage invalide.")
        }
    }
}

public struct ScratchNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String = "Sans titre", text: String = "", updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.text = text; self.updatedAt = updatedAt
    }
}

public struct FocusClock: Codable, Equatable {
    public var duration: TimeInterval
    public var remainingWhenPaused: TimeInterval
    public var deadline: Date?
    public init(duration: TimeInterval = 25 * 60) {
        self.duration = duration; self.remainingWhenPaused = duration
    }
    public func remaining(at date: Date = Date()) -> TimeInterval {
        max(0, deadline.map { $0.timeIntervalSince(date) } ?? remainingWhenPaused)
    }
    public mutating func start(at date: Date = Date()) {
        guard deadline == nil else { return }
        if remainingWhenPaused <= 0 { remainingWhenPaused = duration }
        deadline = date.addingTimeInterval(remainingWhenPaused)
    }
    public mutating func pause(at date: Date = Date()) {
        remainingWhenPaused = remaining(at: date); deadline = nil
    }
    public mutating func reset(duration: TimeInterval? = nil) {
        if let duration { self.duration = max(1, duration) }
        remainingWhenPaused = self.duration; deadline = nil
    }
    public mutating func finishIfNeeded(at date: Date = Date()) -> Bool {
        guard let deadline, deadline <= date else { return false }
        self.deadline = nil; remainingWhenPaused = 0; return true
    }
}

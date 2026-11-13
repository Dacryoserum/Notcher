import Foundation

/// French is the language of the source. Every displayed string goes through this lookup, which
/// returns the translation of the running app, or the text itself when there is none.
public func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

/// Same lookup for a text with values: `L("%lld fichiers", count)`.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}

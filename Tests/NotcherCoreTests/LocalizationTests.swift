import XCTest

/// French text is the translation key. Rewording a French sentence in the code silently drops its English
/// translation; these tests turn that into a failure.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Words that read the same in both languages, and literals that are never shown.
    private static let identical: Set<String> = [
        "Agents", "Spotify", "Pistolame", "Music", "+15 min", "+30 min", "Animation", "Mac", "Widgets", "Services",
        "1 h", "24 h", "Claude Code", "Codex", "AirDrop", "Bluetooth", "Format", "Compact", "Pomodoro", "Volume",
        "Quotas", "Session", "%lld min", "%lld fichiers",
        // Claude Code hook event names.
        "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"
    ]

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.root.appendingPathComponent("App/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language) table is not a string table")
    }

    /// Literals handed to the views and to L(), in every source file.
    private func displayedKeys() throws -> [String: String] {
        let literal = #""((?:[^"\\]|\\.)*)""#
        let patterns = [
            #"\bL\(\s*"#, #"\bText\(\s*"#, #"\bButton\(\s*"#, #"\bLabel\(\s*"#, #"\bTextField\(\s*"#, #"\bToggle\(\s*"#,
            #"\bPicker\(\s*"#, #"\bStepper\(\s*"#, #"\bColorPicker\(\s*"#, #"\.help\(\s*"#, #"\bconfirmationDialog\(\s*"#,
            #"\b(?:title|subtitle|hint|help|text|button):\s*"#, #"\bnotify\(\s*"#, #"\bnotifyWhenOpen\(\s*"#, #"\bfailed\(\s*"#,
            #"\bcase\s+\w+\s*=\s*"#, #",\s*\w+\s*=\s*"#
        ].map { try! NSRegularExpression(pattern: $0 + literal) }
        var found: [String: String] = [:]
        let sources = Self.root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for pattern in patterns {
                    for match in pattern.matches(in: line, range: range) {
                        guard let keyRange = Range(match.range(at: 1), in: line) else { continue }
                        let key = String(line[keyRange])
                        // Interpolated text cannot be looked up; text without a letter needs no translation.
                        guard !key.contains("\\("), key.rangeOfCharacter(from: .letters) != nil else { continue }
                        found[key] = found[key] ?? "\(file.lastPathComponent):\(number + 1)"
                    }
                }
            }
        }
        return found
    }

    func testEveryDisplayedTextHasAnEnglishTranslation() throws {
        let english = try table("en")
        let missing = try displayedKeys().filter { english[$0.key] == nil && !Self.identical.contains($0.key) }
        XCTAssertTrue(missing.isEmpty, "Sans traduction anglaise :\n" + missing.map { "  \($0.value)  \($0.key)" }.sorted().joined(separator: "\n"))
    }
    func testBothLanguagesHaveTheSameKeys() throws {
        let english = Set(try table("en").keys), french = Set(try table("fr").keys)
        XCTAssertEqual(english.subtracting(french).sorted(), [], "Absent du français")
        XCTAssertEqual(french.subtracting(english).sorted(), [], "Absent de l’anglais")
    }
    /// A translation with other placeholders than its key formats the wrong value, or crashes.
    func testTranslationsKeepTheirPlaceholders() throws {
        let placeholder = try NSRegularExpression(pattern: "%(?:lld|ld|d|@|%)")
        func specifiers(_ text: String) -> [String] {
            placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
        }
        for language in ["en", "fr"] {
            for (key, value) in try table(language) where specifiers(key) != specifiers(value) {
                XCTFail("\(language) : « \(key) » → « \(value) »")
            }
        }
    }
}

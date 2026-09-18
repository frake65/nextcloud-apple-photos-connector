import XCTest
@testable import MacAgent

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "de", "fr", "pt", "nl", "es"]

    func testEveryKeyHasAnExplicitTranslationInEverySupportedLanguage() {
        XCTAssertEqual(Set(L10n.supportedLanguages.filter { $0 != "system" }), Set(languages))
        for (key, translations) in L10n.values {
            for language in languages {
                XCTAssertFalse(translations[language, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Missing \(key)/\(language)")
                XCTAssertEqual(L10n.text(key, language: language), translations[language])
            }
        }
    }

    func testAllLiteralUIKeysResolveAndFormattingArgumentsMatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/MacAgent")
        let pattern = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\("([^"]+)""#)
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = String(source[Range(match.range(at: 1), in: source)!])
                XCTAssertNotNil(L10n.values[key], "Unknown key \(key) in \(file.lastPathComponent)")
            }
        }
        let placeholder = try NSRegularExpression(pattern: #"%(?:\d+\$)?[d@]"#)
        func arguments(_ value: String) -> [String] {
            placeholder.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }.sorted()
        }
        for (key, translations) in L10n.values {
            for language in languages {
                XCTAssertEqual(arguments(translations[language] ?? ""), arguments(translations["en"] ?? ""), "Placeholder mismatch \(key)/\(language)")
            }
        }
    }

    func testConnectionAndResetWordingAndRetiredKeys() {
        XCTAssertEqual(L10n.text("loginFlowConnect", language: "en"), "Connect to Nextcloud")
        XCTAssertEqual(L10n.text("loginFlowConnected", language: "en"), "✓ Connected to Nextcloud")
        XCTAssertEqual(L10n.text("resetConnection", language: "de"), "Verbindung zurücksetzen")
        XCTAssertEqual(L10n.text("resetConnectionTitle", language: "en"), "Reset Nextcloud connection?")
        XCTAssertEqual(L10n.format("expandFolder", "Holiday", language: "en"), "Expand Holiday")
        for key in ["retryTransfer", "behavior", "disconnect", "disconnectConfirmationTitle", "disconnectConfirmationMessage"] {
            XCTAssertNil(L10n.values[key], "Retired key remains: \(key)")
        }
    }
}

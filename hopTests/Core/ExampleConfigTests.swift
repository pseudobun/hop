import Foundation
import Testing
@testable import hop

/// `examples/` mirrors the templates hop writes on first launch; `just examples` regenerates it.
struct ExampleConfigTests {
    static let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "examples")

    @Test func configExampleMatchesTemplate() throws {
        let text = try String(contentsOf: Self.examples.appending(path: "config.json5"), encoding: .utf8)
        #expect(text == AppSettings.template, "run `just examples`")
    }

    @Test func snippetsExampleMatchesTemplate() throws {
        let text = try String(contentsOf: Self.examples.appending(path: "snippets.json5"), encoding: .utf8)
        #expect(text == SnippetsFile.template, "run `just examples`")
    }

    @MainActor @Test func themeExampleMatchesTemplate() throws {
        let text = try String(contentsOf: Self.examples.appending(path: "theme.json5"), encoding: .utf8)
        #expect(text == CustomThemes.defaultTemplate, "run `just examples`")
    }
}

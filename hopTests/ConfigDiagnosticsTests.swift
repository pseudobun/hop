import Foundation
import Testing
@testable import hop

struct ConfigDiagnosticsTests {
    private func issue(_ text: String) -> ConfigIssue? {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        do {
            _ = try decoder.decode(HopConfig.self, from: Data(text.utf8))
            return nil
        } catch {
            return ConfigDiagnostics.issue(for: error, in: text)
        }
    }

    @Test func missingCommaPointsAtThePreviousValue() {
        let text = """
        {
          general: {
            hotkey: "cmd+space"
            sensitivity: "high",
          },
        }
        """
        let i = issue(text)
        #expect(i?.message == #"Line 3: expected "," or "}" after a value"#)
        #expect(i?.line == 3)
        #expect(i?.column == 23)
    }

    @Test func syntaxErrorsInPlainWords() {
        #expect(issue("{\n  general: {\n    hotkey \"x\",\n  },\n}")?.message == #"Line 3: expected ":" after the key"#)
        #expect(issue("{ general: {}, }\n}")?.message == "Line 2: '}' after the config's closing }")
        #expect(issue("{\n  shelf: { shake: tru },\n}")?.message == "Line 2: expected true or false")
        let unclosed = issue("{\n  general: {\n    hotkey: \"cmd+space,\n  },\n}")
        #expect(unclosed?.message == "Line 3: this string is never closed")
        #expect(unclosed?.column == 13)
        #expect(issue("{\n  general: {\n    hotkey: \"a\",\n")?.message == "Line 2: the file ends before this { is closed")
        #expect(issue("{\n  // 1.5 here is a comment\n  files: { maxResults: 1.5 },\n}")?.message
            == "Line 3: 1.5 is not allowed here, use a whole number")
    }

    @Test func typeMismatchNamesTheKeyAndItsLine() {
        let text = """
        {
          // files
          files: {
            enabled: true,
            maxResults: "lots",
          },
        }
        """
        let i = issue(text)
        #expect(i?.message == "files.maxResults (line 5): expected a whole number, found a string")
        #expect(i?.line == 5)
        #expect(i?.column == 5)
        #expect(issue("{ shelf: [] }")?.message == "shelf (line 1): expected a section { … }, found an array")
        #expect(issue("{\n  bookmarks: [\n    { name: 1 },\n  ],\n}")?.message
            == "bookmarks[0].name (line 3): expected a string, found a number")
    }

    @Test func badEnumValueListsTheAllowedOnes() {
        let text = "{\n  general: { sensitivity: \"low\" },\n  shelf: {\n    shakeSensitivity: \"huge\",\n  },\n}"
        let i = issue(text)
        #expect(i?.message == #"shelf.shakeSensitivity (line 4): "huge" is not one of low, medium, high"#)
        #expect(i?.line == 4)
        let db = "{ keepass: { databases: [{ path: \"a\" }, { password: 'ask' }] } }"
        #expect(issue(db)?.message == #"keepass.databases[1].password (line 1): "ask" is not one of keychain, prompt, command, none"#)
    }

    @Test func unknownKeysWarnWithSuggestions() {
        let text = """
        {
          general: { hotkey: "cmd+space" },
          shelf: {
            shakeSensitivty: "high",
            fooBar: 1,
          },
          hotkeys: { "Anything Goes": "hyper+a" },
          bookmarks: [{ name: "x", ulr: "y" }],
          notess: { enabled: true, nested: 1 },
        }
        """
        #expect(issue(text) == nil) // the config still applies
        let messages = ConfigDiagnostics.warnings(in: text).map(\.message)
        #expect(messages == [
            "shelf.shakeSensitivty (line 4): unknown key, did you mean shakeSensitivity?",
            "shelf.fooBar (line 5): unknown key",
            "bookmarks[0].ulr (line 8): unknown key, did you mean url?",
            "notess (line 9): unknown key, did you mean notes?",
        ])
        #expect(ConfigDiagnostics.warnings(in: AppSettings.template).isEmpty)
        #expect(ConfigDiagnostics.suggestion(for: "hyperkey", among: ["hyperKey", "general"]) == "hyperKey")
        #expect(ConfigDiagnostics.suggestion(for: "zzz", among: ["general", "shelf"]) == nil)
        #expect(ConfigDiagnostics.editDistance("kitten", "sitting") == 3)
    }

    @Test func schemaComesFromTheConfigTypes() {
        #expect(ConfigSchema.hop.node(at: ["shelf", "shakeSensitivity"]) == .choice(["low", "medium", "high"]))
        #expect(ConfigSchema.hop.node(at: ["general", "sensitivity"]) == .choice(["low", "medium", "high"]))
        #expect(ConfigSchema.hop.node(at: ["hotkeys"]) == .anyKeys)
        #expect(ConfigSchema.hop.node(at: ["bookmarks", "0", "aliases"]) == .list(.value))
        #expect(ConfigSchema.hop.node(at: ["general", "nope"]) == nil)
    }

    @Test func editorLaunchJumpsToTheLine() {
        let file = URL(fileURLWithPath: "/Users/me/My Config/config.json5")
        let app = URL(fileURLWithPath: "/Applications/X.app")
        func launch(_ id: String?, line: Int? = 42, column: Int? = 7) -> ConfigOpener.Launch {
            ConfigOpener.launch(bundleID: id, app: app, file: file, line: line, column: column)
        }
        #expect(launch("com.microsoft.VSCode") == .url(URL(string: "vscode://file/Users/me/My%20Config/config.json5:42:7")!))
        #expect(launch("com.todesktop.230313mzl4w4u92") == .url(URL(string: "cursor://file/Users/me/My%20Config/config.json5:42:7")!))
        #expect(launch("com.microsoft.VSCodeInsiders", column: nil)
            == .url(URL(string: "vscode-insiders://file/Users/me/My%20Config/config.json5:42:1")!))
        #expect(launch("dev.zed.Zed") == .command("/Applications/X.app/Contents/MacOS/cli", ["/Users/me/My Config/config.json5:42:7"]))
        #expect(launch("com.sublimetext.4")
            == .command("/Applications/X.app/Contents/SharedSupport/bin/subl", ["/Users/me/My Config/config.json5:42:7"]))
        #expect(launch("com.macromates.TextMate")
            == .url(URL(string: "txmt://open?url=file:///Users/me/My%2520Config/config.json5&line=42&column=7")!))
        #expect(launch("com.apple.TextEdit") == .plain)
        #expect(launch("com.microsoft.VSCode", line: nil) == .plain)
        #expect(launch(nil) == .plain)
    }
}

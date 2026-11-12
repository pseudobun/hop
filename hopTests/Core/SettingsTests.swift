import AppKit
import Foundation
import Testing
@testable import hop

struct ConfigEditPathTests {
    private func decode(_ text: String) throws -> HopConfig {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        return try d.decode(HopConfig.self, from: Data(text.utf8))
    }

    @Test func replacesNestedValueKeepingComments() throws {
        let text = "{\n  // keys\n  wireguard: {\n    keys: {\n      // focus\n      focus: \"cmd+j\", // trailing\n    },\n  },\n}\n"
        let out = try #require(ConfigEdit.setting(["wireguard", "keys", "focus"], to: ConfigEdit.literal("cmd+k"), in: text))
        #expect(out == "{\n  // keys\n  wireguard: {\n    keys: {\n      // focus\n      focus: \"cmd+k\", // trailing\n    },\n  },\n}\n")
        #expect(try decode(out).wireguard.keys.focus == "cmd+k")
    }

    @Test func addsMissingKeysAndObjects() throws {
        let text = "{\n  general: {\n    hotkey: \"alt+space\",\n  },\n}\n"
        let a = try #require(ConfigEdit.setting(["general", "openAtLogin"], to: "false", in: text))
        #expect(a == "{\n  general: {\n    openAtLogin: false,\n    hotkey: \"alt+space\",\n  },\n}\n")
        let b = try #require(ConfigEdit.setting(["clipboard", "ignoreApps"], to: ConfigEdit.literal(["a.b", "c.d"]), in: a))
        let config = try decode(b)
        #expect(config.clipboard.ignoreApps == ["a.b", "c.d"])
        #expect(config.general.hotkey == "alt+space")
        #expect(!config.general.openAtLogin)
    }

    @Test func singleLineObjectsAndQuotedKeys() throws {
        let text = "{ \"notes\": { 'folder': \"~/A\" }, emoji: { ai: true } }"
        let out = try #require(ConfigEdit.setting(["notes", "folder"], to: ConfigEdit.literal("~/B \"x\""), in: text))
        #expect(try decode(out).notes.folder == "~/B \"x\"")
        let added = try #require(ConfigEdit.setting(["emoji", "skinTone"], to: ConfigEdit.literal("dark"), in: out))
        #expect(try decode(added).emoji.skinTone == "dark")
        #expect(try decode(added).emoji.ai)
    }

    @Test func ignoresKeysInsideStringsAndComments() throws {
        let text = "{\n  /* hotkey: \"x\" */\n  notes: { template: \"hotkey: y\" },\n  general: { hotkey: \"cmd+space\" },\n}\n"
        let out = try #require(ConfigEdit.setting(["general", "hotkey"], to: ConfigEdit.literal("alt+space"), in: text))
        #expect(try decode(out).general.hotkey == "alt+space")
        #expect(try decode(out).notes.template == "hotkey: y")
        #expect(out.contains("/* hotkey: \"x\" */"))
    }

    @Test func multilineStringsRoundTrip() throws {
        let value = "---\ntitle: {{title}}\n---\n\n"
        let out = try #require(ConfigEdit.setting(["notes", "template"], to: ConfigEdit.literal(value), in: "{}"))
        #expect(try decode(out).notes.template == value)
    }

    @Test func editsTheShippedTemplate() throws {
        var text = AppSettings.template
        for field in SettingsCatalog.pages.flatMap(\.fields) {
            let literal: String = switch SettingsValue.read(field.path, in: HopConfig()) {
            case let b as Bool: ConfigEdit.literal(!b)
            case let n as Int: ConfigEdit.literal(n + 1)
            case let s as String: ConfigEdit.literal(s)
            case let l as [String]: ConfigEdit.literal(l)
            default: "null"
            }
            text = try #require(ConfigEdit.setting(field.path, to: literal, in: text), "\(field.key)")
        }
        let config = try decode(text)
        #expect(config.general.openAtLogin == false)
        #expect(config.clipboard.keepDays == 91)
        #expect(ConfigDiagnostics.warnings(in: text).isEmpty)
    }

    @Test func rejectsTextWithoutAnObject() {
        #expect(ConfigEdit.setting(["a"], to: "1", in: "") == nil)
        #expect(ConfigEdit.setting(["a"], to: "1", in: "// only a comment") == nil)
    }
}

struct SettingsCatalogTests {
    @Test func everyFieldIsAConfigKey() {
        let defaults = HopConfig()
        for field in SettingsCatalog.pages.flatMap(\.fields) {
            #expect(ConfigSchema.hop.node(at: field.path) != nil, "\(field.key)")
            #expect(SettingsValue.read(field.path, in: defaults) != nil, "\(field.key)")
        }
        for page in SettingsCatalog.pages {
            if let gate = page.gate { #expect(SettingsValue.read(gate, in: defaults) is Bool, "\(page.id)") }
        }
    }

    @Test func pageIDsAreUnique() {
        let ids = SettingsCatalog.pages.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func choicesMatchTheConfig() {
        for field in SettingsCatalog.pages.flatMap(\.fields) {
            guard case .choice(let options) = field.kind,
                  case .choice(let allowed) = ConfigSchema.hop.node(at: field.path) else { continue }
            #expect(Set(options.map(\.value)).isSubset(of: Set(allowed)), "\(field.key)")
        }
    }

    @Test func recorderWritesParsableHotkeys() {
        #expect(HotkeyRecorder.spec(keyCode: 49, modifiers: [.command]) == "cmd+space")
        #expect(HotkeyRecorder.spec(keyCode: 8, modifiers: [.shift, .option]) == "alt+shift+c")
        #expect(HotkeyRecorder.spec(keyCode: 40, modifiers: [.command, .control, .option, .shift]) == "hyper+k")
        #expect(HotkeyRecorder.spec(keyCode: 36, modifiers: [.command]) == "cmd+return")
        #expect(HotkeyRecorder.spec(keyCode: 8, modifiers: []) == nil)
    }
}

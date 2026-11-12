import AppKit
import Foundation
import Testing
@testable import hop

/// The built-in plugin registry, plugin config sections and turning plugins on and off.
struct PluginRegistryTests {
    @Test func builtinPluginsHaveUniqueIdsAndPages() {
        let infos = BuiltinPlugins.types.map { $0.info }
        #expect(Set(infos.map(\.id)).count == infos.count)
        let pages = SettingsCatalog.pages.map(\.id)
        #expect(Set(pages).count == pages.count, "a plugin id clashes with a core page id")
        for info in infos {
            #expect(pages.contains(info.id), "\(info.id) has no Settings page")
            #expect(info.tier == .builtin)
        }
        #expect(pages.contains("plugins"))
    }

    @Test func everyConfigSectionHasAKnownKeyAndPlugin() {
        let keys = BuiltinPlugins.configTypes.map { $0.key }
        #expect(Set(keys).count == keys.count)
        let ids = Set(BuiltinPlugins.types.map { $0.info.id })
        // Each section belongs to the plugin with the same id.
        for key in keys { #expect(ids.contains(key), "\(key) section has no plugin") }
    }

    @Test func pluginSwitchesPointAtTheirOwnSection() {
        for info in BuiltinPlugins.types.map({ $0.info }) {
            guard let path = info.enabledPath else { continue }
            #expect(path == [info.id, "enabled"], "\(info.id)")
            #expect(SettingsValue.read(path, in: HopConfig()) as? Bool == info.enabledByDefault, "\(info.id) default")
        }
    }

    @Test func sectionsDecodeAndCompare() throws {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let a = try d.decode(HopConfig.self, from: Data("{ notes: { folder: \"~/A\" }, bookmarks: [{ name: \"x\", url: \"y\" }] }".utf8))
        #expect(a.notes.folder == "~/A")
        #expect(a.bookmarks.map(\.name) == ["x"])
        #expect(a != HopConfig())
        var b = HopConfig()
        b.notes.folder = "~/A"
        b.bookmarks = [HopConfig.Bookmark(name: "x", url: "y")]
        #expect(a == b)
    }

    @Test func installedPluginSettingsLiveUnderPlugins() throws {
        let text = try #require(ConfigEdit.setting(["plugins", "dev.you.thing", "name"], to: ConfigEdit.literal("Bunny"), in: "{}"))
        #expect(text.contains("\"dev.you.thing\""))
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let config = try d.decode(HopConfig.self, from: Data(text.utf8))
        #expect(config.plugins.settings["dev.you.thing"]?["name"]?.string == "Bunny")
        #expect(SettingsValue.read(["plugins", "dev.you.thing", "name"], in: config) as? String == "Bunny")
        #expect(ConfigDiagnostics.warnings(in: text).isEmpty)
    }

    @Test func turningPluginsOnAndOffWritesTheConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try "{\n}\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(url: url)

        // With its own `enabled` key.
        let notes = NotesPlugin.info
        #expect(notes.isEnabled(in: settings.data))
        #expect(notes.setEnabled(false, in: settings))
        #expect(!settings.data.notes.enabled && !notes.isEnabled(in: settings.data))

        // Without one: `plugins.disabled`.
        let paw = PawPlugin.info
        #expect(paw.enabledPath == nil && paw.isEnabled(in: settings.data))
        #expect(paw.setEnabled(false, in: settings))
        #expect(settings.data.plugins.disabled == ["paw"] && !paw.isEnabled(in: settings.data))
        #expect(paw.setEnabled(true, in: settings))
        #expect(settings.data.plugins.disabled.isEmpty && paw.isEnabled(in: settings.data))
        #expect(settings.error == nil && settings.warnings.isEmpty)
    }

    @Test func hiddenFieldsAreFieldsButNotShown() {
        let field = SettingsField(path: ["plugins", "dev.a.b", "token"], "Token", .text(), hidden: true, fallback: "x")
        #expect(field.hidden && field.key == "plugins.dev.a.b.token" && field.fallback as? String == "x")
        let page = PluginInfo(id: "dev.a.b", name: "A", summary: "", symbol: "star", color: .red, category: .installed)
            .page([SettingsSection([.field(field)])])
        // No `enabled` key of its own: the page starts with the plugin switch.
        if case .pluginEnabled = page.sections.first?.rows.first {} else { Issue.record("no switch row") }
        #expect(page.fields.map(\.key) == ["plugins.dev.a.b.token"])
    }

    @Test func shortcutsParse() {
        #expect(KeyCombo.parse("cmd+c") == .cmd("c"))
        #expect(KeyCombo.parse("cmd+shift+return") == .ret([.command, .shift]))
        #expect(KeyCombo.parse("ctrl+delete") == KeyCombo(key: .delete, modifiers: .control))
        #expect(KeyCombo.parse("cmd+nope") == nil)
        #expect(KeyCombo.parse("cmd") == nil)
    }
}

/// `hop` commands come from core and the plugins; names never clash.
struct PluginCLITests {
    @Test func everyCommandNameIsUniqueAndDocumented() {
        let commands = CLI.core + BuiltinPlugins.types.flatMap { $0.cli }
        let names = commands.flatMap(\.names)
        #expect(Set(names).count == names.count, "duplicate: \(names)")
        for command in commands where !command.names.contains("help") {
            #expect(!command.usage.isEmpty, "\(command.names[0]) has no help line")
            for line in command.usage where !line.hasPrefix(" ") {
                #expect(command.names.contains { line.hasPrefix($0 + " ") || line == $0 }, "\(line)")
            }
        }
    }

    @Test func featureCommandsLiveInTheirPlugins() {
        func owner(_ name: String) -> String? {
            BuiltinPlugins.types.first { $0.cli.contains { $0.names.contains(name) } }?.info.id
        }
        #expect(owner("notes") == "notes")
        #expect(owner("kp") == "keepass")
        #expect(owner("wg") == "wireguard")
        #expect(owner("clip") == "clipboard")
        #expect(owner("calc") == "calculator")
        #expect(owner("tr") == "translate" && owner("translate") == "translate")
        #expect(owner("uninstall") == "system")
        #expect(owner("apps") == nil && CLI.core.contains { $0.names.contains("apps") })
    }

    @Test func configPathsAndLiterals() {
        #expect(ConfigJSON.path("notes.folder") == ["notes", "folder"])
        #expect(ConfigJSON.path(#"plugins."dev.you.x".name"#) == ["plugins", "dev.you.x", "name"])
        #expect(ConfigJSON.path("a..b") == nil && ConfigJSON.path(#"a."b"#) == nil)
        #expect(ConfigJSON.literal("true") == "true" && ConfigJSON.literal("5") == "5")
        #expect(ConfigJSON.literal(#"["a", "b"]"#) == #"["a", "b"]"#)
        #expect(ConfigJSON.literal("~/Notes") == #""~/Notes""#)
        #expect(ConfigJSON.display(["plugins", "dev.you.x", "name"]) == #"plugins."dev.you.x".name"#)
    }

    @Test func effectiveConfigHasEverySection() throws {
        let json = ConfigJSON.effective(HopConfig())
        for type in BuiltinPlugins.configTypes { #expect(json[type.key] != nil, "\(type.key)") }
        #expect((json["notes"] as? [String: Any])?["folder"] as? String == "~/Notes")
        #expect(json["sections"] == nil)
        #expect(JSONSerialization.isValidJSONObject(json))
        #expect(ConfigJSON.value(at: ["notes", "folder"], in: HopConfig()) as? String == "~/Notes")
    }

    @Test func setRefusesAValueThatBreaksTheConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try "{\n  // mine\n}\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(url: url)
        #expect(ConfigJSON.write(["notes", "folder"], "~/Vault", in: settings) == 0)
        #expect(settings.data.notes.folder == "~/Vault")
        let before = try String(contentsOf: url, encoding: .utf8)
        #expect(ConfigJSON.write(["notes", "enabled"], "\"yes\"", in: settings) == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
        #expect(before.contains("// mine"))
    }
}

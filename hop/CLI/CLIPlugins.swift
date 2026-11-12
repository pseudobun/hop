import AppKit

/// `hop plugin …`: install, remove, turn on and off, read and change settings, all through the
/// config file, so scripts and agents manage plugins like a person in Settings.
extension CLI {
    static func plugin(_ a: Args) async -> Int32 {
        let words = a.positional
        switch words.first ?? "list" {
        case "list", "ls":
            return listPlugins(json: a.flags.contains("json"))
        case "install", "add":
            guard words.count == 2 else { return Output.fail("usage: hop plugin install <github.com/owner/repo[@tag] | file.hopplugin.zip> [--yes]") }
            return await installPlugin(words[1], yes: a.yes)
        case "remove", "rm", "uninstall":
            guard words.count == 2 else { return Output.fail("usage: hop plugin remove <id> [--yes]") }
            return removePlugin(words[1], yes: a.yes)
        case "enable", "disable", "on", "off":
            guard words.count == 2 else { return Output.fail("usage: hop plugin enable | disable <id>") }
            return setPlugin(words[1], enabled: words[0] == "enable" || words[0] == "on")
        case "settings", "config":
            guard words.count == 2 else { return Output.fail("usage: hop plugin settings <id> [--json]") }
            return pluginSettings(words[1], json: a.flags.contains("json"))
        case "set":
            guard words.count >= 4 else { return Output.fail("usage: hop plugin set <id> <key> <value>   (\"-\" reads a secret from stdin)") }
            return setPluginValue(words[1], key: words[2], raw: words[3...].joined(separator: " "))
        case "sync":
            return await syncPlugins(yes: a.yes)
        default:
            return Output.fail("usage: hop plugin list | install | remove | enable | disable | settings | set | sync (hop help)")
        }
    }

    // MARK: Finding plugins

    /// A plugin by id: its info, settings page and, for installed ones, its folder entry.
    struct PluginRef {
        var info: PluginInfo
        var settings: [SettingsSection]
        var entry: InstalledPlugins.Entry?
    }

    static func pluginRef(_ id: String) -> PluginRef? {
        if let type = BuiltinPlugins.types.first(where: { $0.info.id == id }) {
            return PluginRef(info: type.info, settings: type.settings, entry: nil)
        }
        guard let entry = InstalledPlugins.entries().first(where: { $0.manifest.id == id }) else { return nil }
        let plugin = ExternalPlugin(manifest: entry.manifest, directory: entry.directory, record: entry.record)
        return PluginRef(info: plugin.info, settings: plugin.settings, entry: entry)
    }

    private static func unknown(_ id: String) -> Int32 { Output.fail("no plugin \(id) (hop plugin list)") }

    // MARK: Commands

    private static func listPlugins(json: Bool) -> Int32 {
        let settings = AppSettings()
        let config = settings.data
        var rows: [[String: Any]] = BuiltinPlugins.types.map { type in
            let info = type.info
            return ["id": info.id, "name": info.name, "summary": info.summary, "tier": info.tier.label.lowercased(),
                    "enabled": info.isEnabled(in: config), "commands": type.cli.map { $0.names[0] }]
        }
        let entries = InstalledPlugins.entries()
        for entry in entries {
            let m = entry.manifest
            var row: [String: Any] = ["id": m.id, "name": m.name, "summary": m.summary, "version": m.version, "tier": "community",
                                      "enabled": !config.plugins.disabled.contains(m.id),
                                      "inConfig": config.plugins.install.map { links in links.contains { PluginSync.matches($0, entry) } } ?? true]
            if let cli = m.cli { row["commands"] = [cli.name] }
            if let r = entry.record { row["source"] = r.repository.hasPrefix("local") ? r.repository : "github.com/\(r.repository)@\(r.tag)" }
            rows.append(row)
        }
        let plan = PluginSync.plan(config, entries: entries)
        if json {
            Output.json(["plugins": rows, "pendingInstall": plan.install, "pendingRemove": plan.remove])
            return 0
        }
        for row in rows {
            let on = (row["enabled"] as? Bool) == true ? "on " : "off"
            let extra = [row["version"], row["source"]].compactMap { $0 as? String }.joined(separator: "  ")
            print("\(on)  \(row["tier"] as? String ?? "")\t\(row["id"] as? String ?? "")\t\(row["name"] as? String ?? "")  \(extra)")
        }
        for link in plan.install { print("pending  install\t\(link)  (plugins.install; hop plugin sync)") }
        for id in plan.remove { print("pending  remove \t\(id)  (not in plugins.install; hop plugin sync)") }
        return 0
    }

    private static func describe(_ staged: PluginInstaller.Staged) {
        let m = staged.manifest, r = staged.record
        print("\(m.name) \(m.version)  (\(m.id))")
        let origin = r.repository.hasPrefix("local") ? r.repository : "github.com/\(r.repository) @ \(r.tag)"
        print("from \(origin)\(m.author.map { ", by \($0)" } ?? "")")
        print("community plugin: not reviewed by hop")
        print("sha256 \(r.sha256)")
        let uses = m.permissions.lines
        print(uses.isEmpty ? "declares no network, clipboard, file or program use" : "says it uses:\n  " + uses.joined(separator: "\n  "))
        print("it runs as its own program with your user's access to files and the network")
    }

    private static func installPlugin(_ link: String, yes: Bool) async -> Int32 {
        let staged: PluginInstaller.Staged
        do { staged = try await PluginInstaller.fetch(link) } catch { return Output.fail("\(error)") }
        describe(staged)
        guard yes else {
            PluginInstaller.discard(staged)
            return Output.dryRun()
        }
        do {
            let dir = try PluginInstaller.commit(staged)
            print("installed in \(dir.path)")
        } catch {
            return Output.fail("\(error)")
        }
        if !PluginSync.recordInstall(PluginSync.link(for: staged.record, typed: link), settings: AppSettings()) {
            FileHandle.standardError.write(Data("hop: installed, but plugins.install in the config could not be updated\n".utf8))
        }
        notifyRunningHop()
        return 0
    }

    private static func removePlugin(_ id: String, yes: Bool) -> Int32 {
        guard InstalledPlugins.entries().contains(where: { $0.manifest.id == id }) else {
            return Output.fail("\(id) is not an installed plugin (built-in plugins are turned off with hop plugin disable)")
        }
        guard yes else {
            print("would remove \(id), its Keychain secrets and its plugins.install entry")
            return Output.dryRun()
        }
        PluginSync.recordRemoval(id, settings: AppSettings())
        do { try PluginInstaller.remove(id: id) } catch { return Output.fail("\(error)") }
        print("removed \(id)")
        notifyRunningHop()
        return 0
    }

    private static func setPlugin(_ id: String, enabled: Bool) -> Int32 {
        guard let ref = pluginRef(id) else { return unknown(id) }
        guard ref.info.setEnabled(enabled, in: AppSettings()) else { return Output.fail("could not write the config") }
        print("\(id) \(enabled ? "on" : "off")")
        return 0
    }

    private static func pluginSettings(_ id: String, json: Bool) -> Int32 {
        guard let ref = pluginRef(id) else { return unknown(id) }
        let config = AppSettings().data
        let fields = ref.settings.flatMap(\.rows).compactMap { if case .field(let f) = $0 { f } else { nil } }
        let defaults = HopConfig()
        let rows: [[String: Any]] = fields.map { f in
            var row: [String: Any] = ["key": ConfigJSON.display(f.path), "label": f.label, "type": f.kind.name, "hidden": f.hidden]
            if let help = f.help { row["help"] = help }
            if case .secret(let service, let account) = f.kind {
                row["value"] = Keychain.read(service: service, account: account) == nil ? "unset" : "set (in the Keychain)"
            } else {
                row["value"] = ConfigJSON.plain(SettingsValue.read(f.path, in: config) ?? f.fallback ?? NSNull())
                row["default"] = ConfigJSON.plain(SettingsValue.read(f.path, in: defaults) ?? f.fallback ?? NSNull())
            }
            if case .choice(let options) = f.kind { row["options"] = options.map(\.value) }
            return row
        }
        let section = ConfigJSON.effective(config)[id]
        if json {
            var out: [String: Any] = ["id": id, "enabled": ref.info.isEnabled(in: config),
                                      "enabledKey": ref.info.enabledPath?.joined(separator: ".") ?? "plugins.disabled", "settings": rows]
            // Every key of a built-in plugin's section, including ones without a control.
            if let section { out["config"] = section }
            Output.json(out)
            return 0
        }
        print("\(ref.info.name) (\(id)): \(ref.info.isEnabled(in: config) ? "on" : "off")")
        for row in rows {
            let hidden = (row["hidden"] as? Bool) == true ? "  (config only)" : ""
            let value = row["value"].map { ConfigJSON.text($0) } ?? ""
            print("  \(row["key"] as? String ?? "")\t\(row["type"] as? String ?? "")\t\(value)\(hidden)")
        }
        if rows.isEmpty { print("  no settings") }
        return 0
    }

    private static func setPluginValue(_ id: String, key: String, raw: String) -> Int32 {
        guard let ref = pluginRef(id) else { return unknown(id) }
        let settings = AppSettings()
        if ref.entry != nil {
            guard let pref = ref.entry?.manifest.preferences.first(where: { $0.id == key }) else {
                return Output.fail("\(id) has no setting \(key) (hop plugin settings \(id))")
            }
            if pref.type == .secret {
                let value = raw == "-" ? (stdinText() ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : raw
                let ok = Keychain.write(value, service: ExternalPlugin.keychainService(id), account: key, label: "hop: \(pref.title)")
                if ok { print("\(key) saved in the Keychain") }
                return ok ? 0 : Output.fail("the Keychain refused \(key)")
            }
            return ConfigJSON.write(["plugins", id, key], raw, in: settings)
        }
        guard PluginConfigs.types.contains(where: { $0.key == id }), let sub = ConfigJSON.path(key) else {
            return Output.fail("\(id) has no settings in the config")
        }
        // "folder" or "notes.folder" both mean notes.folder.
        let path = sub.first == id && sub.count > 1 ? sub : [id] + sub
        return ConfigJSON.write(path, raw, in: settings)
    }

    private static func syncPlugins(yes: Bool) async -> Int32 {
        let settings = AppSettings()
        guard settings.data.plugins.install != nil else {
            print("plugins.install is not in the config: installed plugins are managed by hand")
            return 0
        }
        let plan = PluginSync.plan(settings.data, entries: InstalledPlugins.entries())
        if plan.isEmpty {
            print("in sync")
            return 0
        }
        for link in plan.install { print("install \(link)") }
        for id in plan.remove { print("remove  \(id)") }
        guard yes else { return Output.dryRun() }
        var failed = false, installedIDs: Set<String> = []
        for link in plan.install {
            do {
                let staged = try await PluginInstaller.fetch(link)
                _ = try PluginInstaller.commit(staged)
                installedIDs.insert(staged.manifest.id)
                print("installed \(staged.manifest.id) \(staged.manifest.version)")
            } catch {
                failed = true
                FileHandle.standardError.write(Data("hop: \(link): \(error)\n".utf8))
            }
        }
        // A new tag of an installed plugin replaced it in place: nothing to remove.
        for id in plan.remove where !installedIDs.contains(id) {
            do {
                try PluginInstaller.remove(id: id)
                print("removed \(id)")
            } catch {
                failed = true
                FileHandle.standardError.write(Data("hop: \(id): \(error)\n".utf8))
            }
        }
        notifyRunningHop()
        return failed ? 1 : 0
    }

    /// A running hop loads the plugins folder again.
    static func notifyRunningHop() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID).isEmpty else { return }
        let reply = HopIPC.send(.init(verb: .pluginsChanged))
        if !reply.ok { FileHandle.standardError.write(Data("hop: the running hop did not reload plugins; restart it\n".utf8)) }
    }
}

extension SettingsField.Kind {
    /// The kind's name for `hop plugin settings`.
    var name: String {
        switch self {
        case .toggle: "toggle"
        case .text: "text"
        case .hotkey: "hotkey"
        case .number: "number"
        case .choice: "choice"
        case .list: "list"
        case .multiline: "textarea"
        case .secret: "secret"
        }
    }
}

extension ConfigJSON {
    /// A key path as `hop config get` reads it: keys with dots in quotes.
    static func display(_ path: [String]) -> String {
        path.map { $0.contains(".") ? "\"\($0)\"" : $0 }.joined(separator: ".")
    }

    /// One line for a value: strings as they are, the rest as JSON.
    static func text(_ value: Any) -> String {
        if let s = value as? String, !s.contains("\n") { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

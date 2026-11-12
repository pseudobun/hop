import AppKit

extension CLI {
    /// `hop plugin list | install <github link> [--yes] | remove <id> [--yes]`.
    static func plugin(_ a: Args) async -> Int32 {
        switch a.positional.first ?? "list" {
        case "list", "ls":
            return listPlugins(json: a.flags.contains("json"))
        case "install", "add":
            guard a.positional.count == 2 else { return Output.fail("usage: hop plugin install <github.com/owner/repo[@tag] | file.hopplugin.zip> [--yes]") }
            return await installPlugin(a.positional[1], yes: a.yes)
        case "remove", "rm", "uninstall":
            guard a.positional.count == 2 else { return Output.fail("usage: hop plugin remove <id> [--yes]") }
            return removePlugin(a.positional[1], yes: a.yes)
        default:
            return Output.fail("usage: hop plugin list [--json] | install <link> [--yes] | remove <id> [--yes]")
        }
    }

    private static func listPlugins(json: Bool) -> Int32 {
        let config = AppSettings().data
        var rows: [[String: Any]] = BuiltinPlugins.types.map { type in
            let info = type.info
            return ["id": info.id, "name": info.name, "tier": info.tier.rawValue, "enabled": info.isEnabled(in: config)]
        }
        for entry in InstalledPlugins.entries() {
            let m = entry.manifest
            var row: [String: Any] = ["id": m.id, "name": m.name, "version": m.version,
                                      "tier": entry.record?.verified == true ? "verified" : "community",
                                      "enabled": !config.plugins.disabled.contains(m.id)]
            if let r = entry.record { row["source"] = r.repository.hasPrefix("local") ? r.repository : "github.com/\(r.repository)@\(r.tag)" }
            rows.append(row)
        }
        if json {
            Output.json(rows)
            return 0
        }
        for row in rows {
            let on = (row["enabled"] as? Bool) == true ? "on " : "off"
            let extra = [row["version"], row["source"]].compactMap { $0 as? String }.joined(separator: "  ")
            print("\(on)  \(row["tier"] as? String ?? "")\t\(row["id"] as? String ?? "")\t\(row["name"] as? String ?? "")  \(extra)")
        }
        return 0
    }

    private static func installPlugin(_ link: String, yes: Bool) async -> Int32 {
        let staged: PluginInstaller.Staged
        do {
            staged = try await PluginInstaller.fetch(link)
        } catch {
            return Output.fail("\(error)")
        }
        let m = staged.manifest, r = staged.record
        print("\(m.name) \(m.version)  (\(m.id))")
        let origin = r.repository.hasPrefix("local") ? r.repository : "github.com/\(r.repository) @ \(r.tag)"
        print("from \(origin)\(m.author.map { ", by \($0)" } ?? "")")
        print(r.verified ? "listed in hop's plugin index" : "not reviewed by hop")
        print("sha256 \(r.sha256)")
        let uses = m.permissions.lines
        print(uses.isEmpty ? "declares no network, clipboard, file or program use" : "says it uses:\n  " + uses.joined(separator: "\n  "))
        print("it runs as its own program with your user's access to files and the network")
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
        notifyRunningHop()
        return 0
    }

    private static func removePlugin(_ id: String, yes: Bool) -> Int32 {
        guard InstalledPlugins.entries().contains(where: { $0.manifest.id == id }) else {
            return Output.fail("\(id) is not an installed plugin (built-in plugins are turned off in Settings or the config)")
        }
        guard yes else {
            print("would remove \(id) and its Keychain secrets")
            return Output.dryRun()
        }
        do { try PluginInstaller.remove(id: id) } catch { return Output.fail("\(error)") }
        print("removed \(id)")
        notifyRunningHop()
        return 0
    }

    /// A running hop loads the plugins folder again.
    private static func notifyRunningHop() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID).isEmpty else { return }
        let reply = HopIPC.send(.init(verb: .pluginsChanged))
        if !reply.ok { FileHandle.standardError.write(Data("hop: the running hop did not reload plugins; restart it\n".utf8)) }
    }
}

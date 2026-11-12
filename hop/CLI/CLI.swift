import AppKit
import Carbon.HIToolbox

/// `hop <command>`: the app binary doubles as a CLI for scripts and agents.
/// Destructive commands only describe what they would do unless `--yes` is given.
enum CLI {
    /// hop's own commands; plugins add theirs (`BuiltinPlugin.cli`, `cli` in plugin.json5).
    static let core: [CLICommand] = [
        CLICommand(names: ["help", "--help", "-h"], usage: []) { _ in help() },
        CLICommand(names: ["apps"], usage: ["apps [query] [--json]               List apps, ranked like the launcher"], run: apps),
        CLICommand(names: ["open"], usage: ["open <query>                        Open the best-matching app"], run: openApp),
        CLICommand(names: ["config"], usage: [
            "config path | check | show | template   Inspect ~/.config/hop/config.json5; template prints the full default",
            "config get <key.path> [--json]      Print one value (\"notes.folder\", \"plugins.disabled\")",
            "config set <key.path> <value>       Write one value (JSON5: true, 5, \"text\", [\"a\"]), comments kept",
        ], run: config),
        CLICommand(names: ["themes"], usage: [
            "themes [list] | path | check | template [base]   Built-in and custom themes (~/.config/hop/themes/*.json5);",
            "                                    template prints a commented theme file to start from",
        ], run: themes),
        CLICommand(names: ["hotkeys"], usage: ["hotkeys [--json]                    hop's hotkeys, the hotkeys section, and every command you can bind"], run: hotkeys),
        CLICommand(names: ["permissions"], usage: ["permissions [--json]                Which macOS permissions hop has"], run: permissions),
        CLICommand(names: ["plugin", "plugins"], usage: [
            "plugin list [--json]                Plugins, on or off, with their source",
            "plugin install <github link | zip> [--yes]   Install a plugin (owner/repo[@tag] or a .hopplugin.zip); adds it to plugins.install",
            "plugin remove <id> [--yes]          Remove an installed plugin and its plugins.install entry",
            "plugin enable | disable <id>        Turn a plugin on or off in the config",
            "plugin settings <id> [--json]       A plugin's settings: keys, types, defaults, current values",
            "plugin set <id> <key> <value>       Change one setting of a plugin (JSON5 value)",
            "plugin sync [--yes]                 Install what plugins.install lists, remove what it no longer lists",
        ], run: plugin),
        CLICommand(names: ["version", "--version"], usage: ["version                             hop's version and build"]) { _ in version() },
        CLICommand(names: ["update"], usage: ["update [--check] | status           Install the newest version now (hop restarts); --check only looks"]) { a in await update(a) },
    ]

    /// Every command: hop's, the built-in plugins' and the installed plugins'.
    static var all: [CLICommand] {
        core + BuiltinPlugins.types.flatMap { $0.cli } + InstalledPlugins.cliCommands()
    }

    /// Runs a CLI command and exits if argv names one; otherwise returns.
    static func runIfRequested(_ argv: [String]) {
        guard argv.count > 1, !argv[1].hasPrefix("-") || ["-h", "--help", "--version"].contains(argv[1]),
              let command = all.first(where: { $0.names.contains(argv[1]) }) else { return }
        let args = Args(Array(argv.dropFirst(2)))
        Task {
            let code = await command.run(args)
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - Commands

    static func version() -> Int32 {
        print("hop \(AppPaths.version) (\(AppPaths.build))")
        return 0
    }

    /// `hop update`: the running hop installs the newest version and restarts. `--check` only
    /// looks (the HUD answers), `status` prints a downloaded version waiting to install (exit 10).
    static func update(_ a: Args) async -> Int32 {
        guard Updater.isConfigured else {
            return Output.fail("this hop was built from source and has no updater; update it with git pull && just install")
        }
        if a.positional.first == "status" {
            guard let p = PendingUpdate.read() else { print("hop \(AppPaths.version): nothing waiting to install"); return 0 }
            print("hop \(p.version) is downloaded and installs when hop quits, or now with hop update")
            return 10
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID).isEmpty else {
            return Output.fail("hop is not running")
        }
        let check = a.flags.contains("check")
        let reply = HopIPC.send(.init(verb: check ? .updateCheck : .updateInstall))
        guard reply.ok else { return Output.fail(reply.error ?? "hop did not answer") }
        print(check ? "checking in the running hop (current: \(AppPaths.version)); the HUD answers"
                    : "the running hop installs the newest version and restarts, if there is one (current: \(AppPaths.version))")
        return 0
    }

    static func help() -> Int32 {
        print("hop: tiny native launcher. Usage: hop <command> [options]\n")
        for line in core.flatMap(\.usage) { print("  " + line) }
        for type in BuiltinPlugins.types where !type.cli.isEmpty {
            print("\n  \(type.info.name):")
            for line in type.cli.flatMap(\.usage) { print("  " + line) }
        }
        let installed = InstalledPlugins.entries().filter { $0.manifest.cli != nil }
        for entry in installed {
            print("\n  \(entry.manifest.name) (installed):")
            for line in entry.manifest.cli?.usage ?? [] { print("  " + line) }
        }
        print("""

        <app> is a name, a bundle identifier or a path to a .app.
        Without --yes, destructive commands only print what they would do (exit 3).
        """)
        return 0
    }

    static func apps(_ a: Args) async -> Int32 {
        let entries = await AppScanner.scan()
        let config = AppSettings().data
        let cands = entries.map { RankCandidate(id: $0.id, title: $0.name, alternateTitles: $0.alternateNames, typeWeight: 5) }
        let query = a.positional.joined(separator: " ")
        let order = query.isEmpty ? RootRanker.rankEmpty(cands)
            : RootRanker.rank(cands, query: SearchQuery(query), sensitivity: config.general.sensitivity)
        let list = order.map { entries[$0] }
        if a.json {
            Output.json(list.map { ["name": $0.name, "path": $0.path, "bundleID": $0.bundleID ?? "", "kind": "\($0.kind)"] })
        } else {
            for e in list { print("\(e.name)\t\(e.bundleID ?? "-")\t\(e.path)") }
        }
        return 0
    }

    static func openApp(_ a: Args) async -> Int32 {
        guard let entry = await resolveApp(a.positional.joined(separator: " ")) else { return Output.fail("no matching app") }
        NSWorkspace.shared.open(entry.openURL)
        print("opened \(entry.name)")
        return 0
    }








    static func config(_ a: Args) async -> Int32 {
        let settings = AppSettings()
        switch a.positional.first ?? "path" {
        case "path":
            print(settings.url.path)
            return 0
        case "check":
            if let error = settings.error { return Output.fail(error.message) }
            for warning in settings.warnings { print("warning: \(warning.message)") }
            let loaded = CustomThemes.load(from: CustomThemes.folder(beside: settings.url))
            let theme = settings.data.general.theme
            if !theme.isBuiltIn, !loaded.themes.contains(where: { $0.name == theme }) {
                print("warning: general.theme: no theme \"\(theme.rawValue)\" (built-in or in themes/), using \"og\"")
            }
            // The same checks Settings shows under its fields.
            let problems = SettingsCatalog.problems(in: settings.data)
            for (key, problem) in problems { print("\(problem.level == .error ? "error" : "warning"): \(key): \(problem.message)") }
            if problems.contains(where: { $0.problem.level == .error }) { return 1 }
            print("ok")
            return 0
        case "show":
            // Every section with its defaults filled in: what hop actually uses.
            Output.json(ConfigJSON.effective(settings.data))
            return settings.error == nil ? 0 : 1
        case "get":
            guard a.positional.count == 2, let path = ConfigJSON.path(a.positional[1]) else {
                return Output.fail("usage: hop config get <key.path>   (quote keys with dots: plugins.\"dev.you.x\".name)")
            }
            guard let value = ConfigJSON.value(at: path, in: settings.data) else { return Output.fail("no key \(a.positional[1])") }
            if a.flags.contains("json") || !(value is String || value is Int || value is Double || value is Bool) {
                Output.json(value, fragment: true)
            } else {
                print(value)
            }
            return 0
        case "set":
            guard a.positional.count >= 3, let path = ConfigJSON.path(a.positional[1]) else {
                return Output.fail("usage: hop config set <key.path> <value>   (JSON5: true, 5, \"text\", [\"a\", \"b\"]; bare words are text)")
            }
            let raw = a.positional[2...].joined(separator: " ")
            return ConfigJSON.write(path, raw, in: settings)
        case "template":
            print(AppSettings.template, terminator: "")
            return 0
        default:
            return Output.fail("usage: hop config path | check | show | template | get <key> | set <key> <value>")
        }
    }

    static func themes(_ a: Args) async -> Int32 {
        let settings = AppSettings()
        let folder = CustomThemes.folder(beside: settings.url)
        switch a.positional.first ?? "list" {
        case "list":
            let loaded = CustomThemes.load(from: folder)
            let current = settings.data.general.theme
            let builtIn = Theme.Name.builtIn.map { ($0, Theme.spec($0)) }
            Output.json((builtIn + loaded.themes.map { ($0.name, $0.spec) }).map { name, spec in
                var row: [String: Any] = ["id": name.rawValue, "name": spec.label, "description": spec.description,
                                          "light": spec.light, "custom": !name.isBuiltIn, "current": name == current]
                if let file = spec.file { row["file"] = file.path }
                if let base = spec.base { row["base"] = base.rawValue }
                return row
            })
            return 0
        case "path":
            print(folder.path)
            return 0
        case "check":
            let loaded = CustomThemes.load(from: folder)
            for issue in loaded.issues { print("warning: \(issue)") }
            print(loaded.themes.isEmpty ? "ok (no custom themes in \(folder.path))" : "ok (\(loaded.themes.count) custom)")
            return 0
        case "template":
            let base = Theme.Name(rawValue: a.positional.dropFirst().first ?? "og")
            guard let spec = Theme.builtIn(base) else {
                return Output.fail("no built-in theme \"\(base.rawValue)\": \(Theme.Name.builtIn.map(\.rawValue).joined(separator: ", "))")
            }
            print(CustomThemes.template(name: "My Theme", from: spec, base: base), terminator: "")
            return 0
        default:
            return Output.fail("usage: hop themes [list] | path | check | template [base]")
        }
    }





    // MARK: - Helpers




    static func hotkeys(_ a: Args) async -> Int32 {
        let settings = AppSettings()
        let c = settings.data
        let services = Services(settings: settings, frecency: FrecencyStore(store: JSONStore(url: AppPaths.file("frecency.json"))),
                                apps: AppIndex())
        // Plugins' commands exist only in the running hop: ask it.
        var commands: [(id: String, title: String)]
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID).isEmpty
        if running, let list = HopIPC.send(.init(verb: .commands)).commands {
            commands = list.compactMap { $0.count == 2 ? (id: $0[0], title: $0[1]) : nil }
        } else {
            commands = Registry.commands(services).map { (id: $0.id, title: $0.title) }
            FileHandle.standardError.write(Data("hop: hop is not running, so only hop's own commands are listed\n".utf8))
        }
        let windows = [("launcher", "hop launcher"), ("notes.open", "Notes"), ("notes.new", "New Note"),
                       ("clipboard.history", "Clipboard History"), ("keepass.search", "KeePassXC")]
        for w in windows where !commands.contains(where: { $0.id == w.0 }) { commands.append(w) }
        let own = [("general.hotkey", c.general.hotkey), ("notes.hotkey", c.notes.enabled ? c.notes.hotkey : "off"),
                   ("clipboard.hotkey", c.clipboard.enabled ? c.clipboard.hotkey : "off")]
        if a.json {
            Output.json([
                "own": Dictionary(uniqueKeysWithValues: own),
                "hotkeys": c.hotkeys,
                "commands": commands.map { cmd -> [String: String] in
                    var row = ["id": cmd.id, "title": cmd.title]
                    if let h = HotkeyLookup.binding(id: cmd.id, title: cmd.title, in: c.hotkeys) { row["hotkey"] = h }
                    return row
                },
            ])
            return 0
        }
        print("hop's own")
        for (k, v) in own { print("  \(k)\t\(v)") }
        print("\nhotkeys\(c.hotkeys.isEmpty ? " (none yet)" : "")")
        for (k, v) in c.hotkeys.sorted(by: { $0.key < $1.key }) { print("  \(k)\t\(v)") }
        print("\ncommands: bind by title or id; apps by name or app:<bundle id>")
        for cmd in commands {
            let h = HotkeyLookup.binding(id: cmd.id, title: cmd.title, in: c.hotkeys).map { "\t" + $0 } ?? ""
            print("  \(cmd.id)\t\(cmd.title)\(h)")
        }
        return 0
    }



    static func stdinText() -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    static func resolveApp(_ query: String) async -> AppEntry? {
        guard !query.isEmpty else { return nil }
        if query.hasSuffix(".app"), FileManager.default.fileExists(atPath: query.expandingTilde) {
            return AppScanner.entry(for: URL(fileURLWithPath: query.expandingTilde), kind: .application)
        }
        let entries = await AppScanner.scan()
        if let byID = entries.first(where: { $0.bundleID?.lowercased() == query.lowercased() }) { return byID }
        if let exact = entries.first(where: { $0.name.lowercased() == query.lowercased() }) { return exact }
        let cands = entries.map { RankCandidate(id: $0.id, title: $0.name, alternateTitles: $0.alternateNames, typeWeight: 5) }
        return RootRanker.rank(cands, query: SearchQuery(query), sensitivity: .high).first.map { entries[$0] }
    }

    struct Args {
        var positional: [String] = []
        var flags: Set<String> = []
        /// The words as typed, for commands that pass them on (installed plugins).
        let raw: [String]

        init(_ raw: [String]) {
            self.raw = raw
            var i = 0
            while i < raw.count {
                let r = raw[i]
                if r.hasPrefix("--"), let eq = r.firstIndex(of: "=") {
                    options[String(r[r.index(r.startIndex, offsetBy: 2)..<eq])] = String(r[r.index(after: eq)...])
                } else if ["--field", "--db"].contains(r), i + 1 < raw.count {
                    options[String(r.dropFirst(2))] = raw[i + 1]
                    i += 1
                } else if r.hasPrefix("--") {
                    flags.insert(String(r.dropFirst(2)))
                } else {
                    positional.append(r)
                }
                i += 1
            }
        }

        var options: [String: String] = [:]

        var yes: Bool { flags.contains("yes") || flags.contains("y") }

        func option(_ name: String) -> String? { options[name] }
        var json: Bool { flags.contains("json") }
    }

    enum Output {
        static func json(_ value: Any, fragment: Bool = false) {
            var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if fragment { options.insert(.fragmentsAllowed) }
            let data = (try? JSONSerialization.data(withJSONObject: value, options: options)) ?? Data("null".utf8)
            print(String(decoding: data, as: UTF8.self))
        }

        static func fail(_ message: String) -> Int32 {
            fflush(stdout)
            FileHandle.standardError.write(Data("hop: \(message)\n".utf8))
            return 1
        }

        static func dryRun() -> Int32 {
            fflush(stdout)
            FileHandle.standardError.write(Data("hop: dry run, pass --yes to do it\n".utf8))
            return 3
        }
    }
}

import AppKit
import Carbon.HIToolbox

/// `hop <command>`: the app binary doubles as a CLI for scripts and agents.
/// Destructive commands only describe what they would do unless `--yes` is given.
enum CLI {
    static let commands: [String: (Args) async -> Int32] = [
        "help": { _ in help() },
        "--help": { _ in help() },
        "-h": { _ in help() },
        "apps": apps,
        "open": openApp,
        "calc": calc,
        "uninstall": uninstall,
        "downloads": downloads,
        "trash": trash,
        "config": config,
        "hyper": hyper,
        "wg": wireguard,
    ]

    /// Runs a CLI command and exits if argv names one; otherwise returns.
    static func runIfRequested(_ argv: [String]) {
        guard argv.count > 1, let command = commands[argv[1]] else { return }
        let args = Args(Array(argv.dropFirst(2)))
        Task {
            let code = await command(args)
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - Commands

    static func help() -> Int32 {
        print("""
        hop: tiny native launcher. Usage: hop <command> [options]

          apps [query] [--json]               List apps, ranked like the launcher
          open <query>                        Open the best-matching app
          calc <expression>                   Evaluate an expression
          uninstall <app> [--yes] [--json]    Remove an app and its ~/Library leftovers
          downloads clear [--yes] [--json]    Move everything in Downloads to the Trash
          trash count | empty [--yes]         Count or empty the Trash
          config path | check | show          Inspect ~/.config/hop/config.json5
          hyper status | map | unmap          Caps Lock → F20 key mapping (unmap after a crash)
          wg list | up <name> | down <name> | down-all   WireGuard tunnels (WireGuard.app)

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

    static func calc(_ a: Args) async -> Int32 {
        let expr = a.positional.joined(separator: " ")
        do {
            let v = try Calculator.evaluate(expr)
            let s = Calculator.format(v, locale: Locale(identifier: "en_US_POSIX"))
            if a.json { Output.json(["expression": expr, "result": s]) } else { print(s) }
            return 0
        } catch {
            return Output.fail("cannot evaluate: \(expr)")
        }
    }

    static func uninstall(_ a: Args) async -> Int32 {
        let target = a.positional.joined(separator: " ")
        guard !target.isEmpty else { return Output.fail("usage: hop uninstall <app> [--yes]") }
        guard let app = await resolveApp(target) else { return Output.fail("no matching app: \(target)") }
        guard app.kind == .application, UninstallMode.isRemovable(app.path) else {
            return Output.fail("\(app.name) is a system app and cannot be removed")
        }
        let plan = await UninstallPlan.make(for: app)
        if a.json {
            Output.json(["app": app.name, "path": app.path, "cask": plan.cask ?? "", "bytes": plan.totalBytes,
                         "leftovers": plan.leftovers.map(\.url.path), "removed": a.yes])
        } else {
            print("\(app.name)  \(app.path)\(plan.cask.map { "  (brew cask \($0))" } ?? "")")
            for l in plan.leftovers { print("  \(l.url.path)") }
            print("total \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
        }
        guard a.yes else { return Output.dryRun() }
        let result = await plan.execute()
        print(result.message)
        return result.ok ? 0 : 1
    }

    static func downloads(_ a: Args) async -> Int32 {
        guard a.positional.first == "clear" else { return Output.fail("usage: hop downloads clear [--yes]") }
        let dir = URL(fileURLWithPath: AppSettings().data.system.downloadsFolder.expandingTilde)
        let (urls, bytes) = await DownloadsScanner.scan(dir)
        if a.json {
            Output.json(["folder": dir.path, "items": urls.map(\.lastPathComponent), "bytes": bytes, "removed": a.yes])
        } else {
            print("\(urls.count) items, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in \(dir.path)")
        }
        guard a.yes else { return Output.dryRun() }
        let failed = await DownloadsScanner.trash(urls)
        print(failed == 0 ? "moved \(urls.count) items to the Trash" : "\(failed) items could not be moved")
        return failed == 0 ? 0 : 1
    }

    static func trash(_ a: Args) async -> Int32 {
        switch a.positional.first {
        case "count":
            let r = try? await AppleScript.run(#"tell application "Finder" to count items of trash"#)
            guard let r, r.ok else { return Output.fail("Finder did not answer (Automation permission?)") }
            print(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
            return 0
        case "empty":
            guard a.yes else {
                print("would empty the Trash")
                return Output.dryRun()
            }
            let r = try? await AppleScript.run(#"tell application "Finder" to empty trash"#)
            guard r?.ok == true else { return Output.fail("could not empty the Trash") }
            print("Trash emptied")
            return 0
        default:
            return Output.fail("usage: hop trash count | empty [--yes]")
        }
    }

    static func config(_ a: Args) async -> Int32 {
        let settings = AppSettings()
        switch a.positional.first ?? "path" {
        case "path":
            print(settings.url.path)
            return 0
        case "check":
            if let error = settings.error { return Output.fail(error) }
            print("ok")
            return 0
        case "show":
            let c = settings.data
            Output.json([
                "general": ["hotkey": c.general.hotkey, "sensitivity": c.general.sensitivity.rawValue,
                            "popToRootSeconds": c.general.popToRootSeconds, "openAtLogin": c.general.openAtLogin,
                            "menuBarIcon": c.general.menuBarIcon],
                "hyperKey": ["enabled": c.hyperKey.enabled, "quickPressEscape": c.hyperKey.quickPressEscape],
                "wireguard": ["enabled": c.wireguard.enabled, "showFlags": c.wireguard.showFlags],
                "keepass": ["enabled": c.keepass.enabled, "database": c.keepass.database, "keyFile": c.keepass.keyFile,
                            "password": c.keepass.password.rawValue, "lockAfterMinutes": c.keepass.lockAfterMinutes],
                "system": ["downloadsFolder": c.system.downloadsFolder],
            ])
            return settings.error == nil ? 0 : 1
        default:
            return Output.fail("usage: hop config path | check | show")
        }
    }

    static func wireguard(_ a: Args) async -> Int32 {
        let tunnels = await WireGuard.list()
        let sub = a.positional.first ?? "list"
        let name = a.positional.dropFirst().joined(separator: " ")
        func find() -> WireGuardTunnel? {
            tunnels.first { $0.name == name } ?? tunnels.first { $0.name.lowercased().hasPrefix(name.lowercased()) }
        }
        switch sub {
        case "list":
            if a.json {
                Output.json(tunnels.map { ["name": $0.name, "serviceID": $0.serviceID, "status": $0.status, "connected": $0.isConnected] })
            } else if tunnels.isEmpty {
                print("no WireGuard tunnels")
            } else {
                for t in tunnels { print("\(t.isConnected ? "●" : "○") \(t.name)\t\(t.status)") }
            }
            return 0
        case "up", "down":
            guard !name.isEmpty, let t = find() else { return Output.fail("no tunnel named \(name)") }
            guard await WireGuard.setConnected(t, sub == "up") else { return Output.fail("scutil failed for \(t.name)") }
            print("\(t.name): \(sub == "up" ? "connecting" : "disconnecting")")
            return 0
        case "down-all":
            print("disconnected \(await WireGuard.disconnectAll())")
            return 0
        default:
            return Output.fail("usage: hop wg list | up <name> | down <name> | down-all")
        }
    }

    static func hyper(_ a: Args) async -> Int32 {
        switch a.positional.first ?? "status" {
        case "status":
            let mapped = await HyperKeyMapping.current().contains {
                $0["HIDKeyboardModifierMappingSrc"] == HyperKeyMapping.capsLock && $0["HIDKeyboardModifierMappingDst"] == HyperKeyMapping.f20
            }
            let info: [String: Any] = ["enabledInConfig": AppSettings().data.hyperKey.enabled, "capsMappedToF20": mapped,
                                       "accessibility": AXIsProcessTrusted(), "secureInput": IsSecureEventInputEnabled()]
            if a.json { Output.json(info) } else { for (k, v) in info.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") } }
            return 0
        case "map":
            return await HyperKeyMapping.apply() ? 0 : Output.fail("hidutil failed")
        case "unmap":
            return await HyperKeyMapping.restore() ? 0 : Output.fail("hidutil failed")
        default:
            return Output.fail("usage: hop hyper status | map | unmap")
        }
    }

    // MARK: - Helpers

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

        init(_ raw: [String]) {
            for r in raw {
                if r.hasPrefix("--") { flags.insert(String(r.dropFirst(2))) } else { positional.append(r) }
            }
        }

        var yes: Bool { flags.contains("yes") || flags.contains("y") }
        var json: Bool { flags.contains("json") }
    }

    enum Output {
        static func json(_ value: Any) {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data("null".utf8)
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

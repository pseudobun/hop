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
        "convert": convert,
        "uninstall": uninstall,
        "downloads": downloads,
        "trash": trash,
        "config": config,
        "hyper": hyper,
        "wg": wireguard,
        "kp": keepass,
        "ps": processes,
        "kill": killProcess,
        "notes": notes,
        "clip": clip,
        "hotkeys": hotkeys,
        "snippets": snippets,
        "files": files,
        "shelf": shelf,
        "codes": codes,
        "events": events,
        "tr": translate,
        "translate": translate,
        "ocr": ocr,
        "emoji": emoji,
        "bookmarks": bookmarks,
        "permissions": permissions,
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
          convert <query> [--json]            Convert units or currency: "734h to min", "1 sq mile = km2", "100 usd to eur"
          uninstall <app> [--yes] [--json]    Remove an app and its ~/Library leftovers
          downloads clear [--yes] [--json]    Move everything in Downloads to the Trash
          trash count | empty [--yes]         Count or empty the Trash
          ps [query] [--json]                 Running processes, busiest first
          kill <pid|name> [--force] [--yes]   SIGTERM (or SIGKILL with --force) one process
          notes [list] [query] [--json]       Notes in notes.folder (an Obsidian vault), newest first
          notes show <name>                   Print a note
          notes new <title> [text]            Create a note in notes.newNoteFolder (text or stdin)
          notes append <name> [text]          Append text (or stdin) to a note
          notes path                          Print the notes folder
          files <query> [--content] [--json] [--limit=N]   Files by name (or by text with --content), via Spotlight
          shelf <path…>                       Put files on a shelf in the running hop (paths or stdin, one per line)
          codes [--latest] [--minutes=N] [--json]   One-time codes from Messages (needs Full Disk Access)
          events [--days=N] [--birthdays] [--json]  Calendar events from today on (default today only)
          tr <text> [--to=en|sl] [--json]     Translate Slovenian ↔ English with OpenAI (text or stdin)
          ocr [image] [--copy] [--json]       Text in an image, or in an area you select on screen
          emoji <query> [--limit=N] [--json]  Search emoji by name, slang or Slovenian
          bookmarks [query] [--json]          Bookmarks from the config; bookmarks open <name>
          permissions [--json]                Which macOS permissions hop has
          snippets [list] [--json]            Snippets from snippets.json5 with their keywords
          snippets expand <name|keyword> [--arg=value…]   Print a snippet with its placeholders filled in
          snippets add <name> [text] [--keyword=;k]       Append a snippet (text or stdin)
          hotkeys [--json]                    hop's hotkeys, the hotkeys section, and every command you can bind
          clip count                          How many entries the clipboard history holds
          clip [list] [query] [--json] [--limit=N]   Clipboard history, newest first (needs clipboard.cliAccess)
          clip show <n|query> [--json]        Print entry n (1 = newest) or the best match; images print their PNG path
          clip copy <n|query>                 Put an entry back on the clipboard
          config path | check | show          Inspect ~/.config/hop/config.json5
          hyper status | map | unmap          Caps Lock → F20 key mapping (unmap after a crash)
          wg list | up <name> | down <name> | down-all   WireGuard tunnels (WireGuard.app)
          kp dbs | search [query] | get <entry> [--field F] [--db NAME]   KeePassXC (unlocks per call)
              --field: username (default), url, title, password, totp, notes
              password, totp and notes need keepass.cliAccess: true; --password-stdin reads the
              master password from stdin, otherwise keepass.password decides (keychain asks Touch ID)

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

    static func convert(_ a: Args) async -> Int32 {
        let q = a.positional.joined(separator: " ")
        guard let c = Converter.convert(q) else {
            return await convertCurrency(q, json: a.json) ?? Output.fail("cannot convert: \(q)")
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let result = Converter.format(c.result, locale: posix)
        if a.json {
            Output.json(["value": c.value, "from": c.from, "result": c.result, "to": c.to, "formatted": "\(result) \(c.to)"])
        } else {
            print("\(result) \(c.to)")
        }
        return 0
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

    static func processes(_ a: Args) async -> Int32 {
        let all = await Processes.list()
        let q = a.positional.joined(separator: " ")
        let list = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) || String($0.pid) == q }
        if a.json {
            Output.json(list.map { ["pid": $0.pid, "name": $0.name, "path": $0.path, "cpu": $0.cpu, "memoryBytes": $0.memory, "uid": $0.uid] })
        } else {
            for p in list { print(String(format: "%6d  %5.1f%%  %8@  %@", p.pid, p.cpu, ByteCountFormatter.string(fromByteCount: p.memory, countStyle: .memory), p.name)) }
        }
        return 0
    }

    static func killProcess(_ a: Args) async -> Int32 {
        let target = a.positional.joined(separator: " ")
        guard !target.isEmpty else { return Output.fail("usage: hop kill <pid|name> [--force] [--yes]") }
        let all = await Processes.list()
        let matches = Int32(target).map { pid in all.filter { $0.pid == pid } } ?? all.filter { $0.name == target }
        guard let p = matches.first else { return Output.fail("no process \(target)") }
        guard matches.count == 1 else {
            for m in matches { print("\(m.pid)\t\(m.name)") }
            return Output.fail("\(matches.count) processes named \(target), pass a PID")
        }
        let force = a.flags.contains("force")
        print("\(force ? "SIGKILL" : "SIGTERM") \(p.pid) \(p.name)")
        guard a.yes else { return Output.dryRun() }
        switch Processes.kill(p.pid, force: force) {
        case .ok: print("sent"); return 0
        case .gone: return Output.fail("process already exited")
        case .notPermitted: return Output.fail("not permitted (owned by another user)")
        case .failed: return Output.fail("kill failed")
        }
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
            if let error = settings.error { return Output.fail(error.message) }
            for warning in settings.warnings { print("warning: \(warning.message)") }
            print("ok")
            return 0
        case "show":
            let c = settings.data
            Output.json([
                "general": ["hotkey": c.general.hotkey, "sensitivity": c.general.sensitivity.rawValue,
                            "popToRootSeconds": c.general.popToRootSeconds, "keepQueryFor": c.general.keepQueryFor,
                            "fallbacks": c.general.fallbacks, "openAtLogin": c.general.openAtLogin,
                            "menuBarIcon": c.general.menuBarIcon],
                "hyperKey": ["enabled": c.hyperKey.enabled, "quickPressEscape": c.hyperKey.quickPressEscape],
                "wireguard": ["enabled": c.wireguard.enabled, "showFlags": c.wireguard.showFlags,
                              "bar": c.wireguard.bar, "barTunnels": c.wireguard.barTunnels],
                "keepass": ["enabled": c.keepass.enabled, "databases": c.keepass.allDatabases.map { ["name": $0.label, "path": $0.path, "password": $0.password.rawValue] },
                            "autoLock": c.keepass.autoLock, "lockAfterMinutes": c.keepass.lockAfterMinutes, "cliAccess": c.keepass.cliAccess, "favicons": c.keepass.favicons],
                "system": ["downloadsFolder": c.system.downloadsFolder],
                "bookmarks": c.bookmarks.map { ["name": $0.name, "url": $0.url, "aliases": $0.aliases, "icon": $0.icon] },
            ])
            return settings.error == nil ? 0 : 1
        default:
            return Output.fail("usage: hop config path | check | show")
        }
    }

    static func keepass(_ a: Args) async -> Int32 {
        let config = AppSettings().data.keepass
        let dbs = config.allDatabases
        let cli = KeePassCLI.locate(override: config.cli)
        let sub = a.positional.first ?? "status"
        let wanted = a.option("db")
        let db = wanted.flatMap { w in dbs.first { $0.label.lowercased() == w.lowercased() || $0.expandedPath == w.expandingTilde } }
            ?? (wanted == nil ? dbs.first : nil)

        switch sub {
        case "status", "dbs":
            let rows: [[String: Any]] = dbs.map { d in
                ["name": d.label, "path": d.path, "exists": FileManager.default.fileExists(atPath: d.expandedPath),
                 "password": d.password.rawValue, "passwordInKeychain": CredentialVault.hasPassword(account: d.expandedPath)]
            }
            if a.json {
                Output.json(["enabled": config.enabled, "cli": cli ?? "", "cliAccess": config.cliAccess, "databases": rows])
            } else {
                print("enabled: \(config.enabled)\ncli: \(cli ?? "not found")\ncliAccess: \(config.cliAccess)")
                for d in dbs { print("  \(d.label)\t\(d.path)\t\(d.password.rawValue)") }
            }
            return 0
        default: break
        }
        guard config.enabled, !dbs.isEmpty else { return Output.fail(KeePassError.notConfigured.message) }
        guard let db else { return Output.fail("no database named \(wanted ?? "") (see hop kp dbs)") }
        guard let cli else { return Output.fail(KeePassError.cliNotFound.message) }

        let entries: [KeePassEntry]
        do {
            entries = try await KeePassCLI.export(cli: cli, database: db, password: try await masterPassword(db, a))
        } catch let e as KeePassError {
            return Output.fail(e.message)
        } catch {
            return Output.fail(error.localizedDescription)
        }

        let query = a.positional.dropFirst().joined(separator: " ")
        let cands = entries.map { RankCandidate(id: $0.id, title: $0.title, alternateTitles: [$0.username], keywords: [$0.group, $0.url], typeWeight: 1) }
        let ranked = query.isEmpty ? entries : RootRanker.rank(cands, query: SearchQuery(query), sensitivity: .medium).map { entries[$0] }

        switch sub {
        case "search":
            if a.json {
                Output.json(ranked.map { ["title": $0.title, "username": $0.username, "url": $0.url, "group": $0.group,
                                          "hasTOTP": !$0.totp.isEmpty, "database": db.label] })
            } else {
                for e in ranked { print("\(e.title)\t\(e.username)\t\(e.url)\t\(e.group)") }
            }
            return 0
        case "get":
            guard !query.isEmpty, let e = ranked.first else { return Output.fail("no matching entry") }
            let field = a.option("field") ?? "username"
            let secret = ["password", "totp", "notes"].contains(field)
            if secret && !config.cliAccess { return Output.fail("\(field) needs keepass.cliAccess: true in the config") }
            let value: String? = switch field {
            case "username": e.username
            case "url": e.url
            case "title": e.title
            case "password": KeePassPlaceholders.resolve(e.password, e)
            case "notes": e.notes
            case "totp": e.totp.isEmpty ? nil : try? TOTP.code(e.totp)
            default: nil
            }
            guard let value else { return Output.fail("entry \(e.title) has no \(field)") }
            print(value)
            return 0
        default:
            return Output.fail("usage: hop kp dbs | search [query] | get <entry> [--field F] [--db NAME]")
        }
    }

    private static func masterPassword(_ db: HopConfig.KeePass.Database, _ a: Args) async throws -> String? {
        if a.flags.contains("password-stdin") {
            var pw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            while pw.hasSuffix("\n") || pw.hasSuffix("\r") { pw.removeLast() }
            return pw
        }
        switch db.password {
        case .none: return nil
        case .command: return try await KeePassCLI.passwordFromCommand(db.passwordCommand)
        case .keychain:
            let account = db.expandedPath
            guard CredentialVault.hasPassword(account: account) else {
                throw KeePassError.failed("no password in the Keychain yet: unlock \(db.label) once in hop, or use --password-stdin")
            }
            guard await CredentialVault.authenticate(reason: "let hop kp read \(db.label)") else { throw KeePassError.cancelled }
            guard let pw = CredentialVault.load(account: account) else { throw KeePassError.cancelled }
            return pw
        case .prompt:
            throw KeePassError.failed("\(db.label) uses password \"prompt\": pass --password-stdin")
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
            let on = sub == "up"
            print("\(t.name): \(on ? "activating" : "deactivating")…")
            let last = await WireGuard.waitUntilSettled(t, on)
            guard last == (on ? "Connected" : "Disconnected") else {
                return Output.fail("\(t.name): \(last.map(WireGuard.label(for:)) ?? "unknown")")
            }
            print("\(t.name): \(on ? "activated" : "deactivated")")
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

    static func notes(_ a: Args) async -> Int32 {
        let config = AppSettings().data.notes
        let root = URL(fileURLWithPath: config.expandedFolder, isDirectory: true)
        var words = a.positional
        let sub = ["list", "show", "new", "append", "path"].contains(words.first ?? "") ? words.removeFirst() : "list"
        if sub == "path" {
            print(root.path)
            return 0
        }
        let all: [NoteFile]
        do { all = try NoteStore.scan(root) } catch { return Output.fail("cannot read \(root.path): \(error.localizedDescription)") }
        let name = words.joined(separator: " ")
        let find = { (name: String) in
            NoteStore.resolve(link: name, in: all) ?? NoteStore.search(all, query: name, contents: [:]).first?.note
        }
        switch sub {
        case "show":
            guard !name.isEmpty, let note = find(name) else { return Output.fail("no note matches: \(name)") }
            guard let text = NoteStore.readCoordinated(note.url) else { return Output.fail("cannot read \(note.relativePath)") }
            if a.json { Output.json(["path": note.relativePath, "title": note.title, "text": text]) } else { print(text, terminator: "") }
            return 0
        case "new":
            guard let title = words.first, !title.isEmpty else { return Output.fail("usage: hop notes new <title> [text]") }
            let text = words.count > 1 ? words.dropFirst().joined(separator: " ") : stdinText() ?? ""
            let dir = root.appending(path: config.newNoteFolder, directoryHint: .isDirectory)
            let url = NoteStore.uniqueURL(in: dir, title: title, taken: Set(all.map { $0.title.lowercased() }))
            let finalTitle = (url.lastPathComponent as NSString).deletingPathExtension
            let head = NoteStore.render(template: config.template, title: finalTitle, date: Date())
            do { try NoteStore.write(head + text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n"), to: url) }
            catch { return Output.fail(error.localizedDescription) }
            print(url.path)
            return 0
        case "append":
            guard let target = words.first, let note = find(target) else { return Output.fail("usage: hop notes append <name> [text]") }
            guard let addition = words.count > 1 ? words.dropFirst().joined(separator: " ") : stdinText(), !addition.isEmpty else {
                return Output.fail("nothing to append")
            }
            guard var text = NoteStore.readCoordinated(note.url) else { return Output.fail("cannot read \(note.relativePath)") }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += addition + (addition.hasSuffix("\n") ? "" : "\n")
            if config.bumpUpdated { text = NoteStore.bumpUpdated(text, date: Date()) }
            do { try NoteStore.write(text, to: note.url) } catch { return Output.fail(error.localizedDescription) }
            print(note.url.path)
            return 0
        default:
            let contents = name.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: all.compactMap { n in NoteStore.read(n.url).map { (n.relativePath, $0) } })
            let hits = NoteStore.search(all, query: name, contents: contents)
            if a.json {
                Output.json(hits.map { h -> [String: Any] in
                    var row: [String: Any] = ["path": h.note.relativePath, "title": h.note.title,
                                              "modified": ISO8601DateFormatter().string(from: h.note.modified)]
                    if let s = h.snippet { row["match"] = s }
                    if h.matches > 0 { row["matches"] = h.matches }
                    return row
                })
            } else {
                for h in hits { print("\(h.note.title)\t\(h.note.relativePath)\(h.snippet.map { "\t" + $0 } ?? "")") }
            }
            return 0
        }
    }

    static func files(_ a: Args) async -> Int32 {
        let config = AppSettings().data.files
        let words = a.positional
        guard !words.isEmpty else { return Output.fail("usage: hop files <query> [--content] [--json]") }
        let scopes = config.scopes.map(\.expandingTilde)
        let query = a.flags.contains("content") ? Spotlight.contentQuery(words) : Spotlight.nameQuery(words, substring: true)
        let now = Date()
        let hits = Spotlight.run(query, scopes: scopes, limit: 1500)
            .filter { !FilePaths.isExcluded($0.path, patterns: config.exclude, scopes: scopes) }
            .sorted { FilePaths.recency($0, now: now) > FilePaths.recency($1, now: now) }
            .prefix(a.option("limit").flatMap(Int.init) ?? 30)
        if a.json {
            Output.json(hits.map { ["path": $0.path, "folder": $0.isDirectory] as [String: Any] })
        } else {
            for h in hits { print(h.path) }
        }
        return hits.isEmpty ? 1 : 0
    }

    static func snippets(_ a: Args) async -> Int32 {
        let config = AppSettings().data
        let file = SnippetsFile(url: URL(fileURLWithPath: config.snippets.file.expandingTilde))
        file.load()
        if let error = file.error { return Output.fail(error) }
        var words = a.positional
        let sub = ["list", "expand", "add"].contains(words.first ?? "") ? words.removeFirst() : "list"
        switch sub {
        case "expand":
            let key = words.joined(separator: " ")
            guard let s = file.snippets.first(where: { $0.keyword == key }) ?? file.snippets.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })
            else { return Output.fail("no snippet named or keyed \(key)") }
            let args = a.options.filter { $0.key != "keyword" }
            var values: [String] = []
            for (i, arg) in s.arguments.enumerated() {
                values.append(arg.name.flatMap { args[$0] } ?? args["\(i + 1)"] ?? "")
            }
            var ctx = Placeholders.Context()
            ctx.snippets = file.snippets
            ctx.arguments = values
            ctx.calculate = { (try? Calculator.evaluate($0)).map { Calculator.format($0, locale: Locale(identifier: "en_US_POSIX")) } }
            let history = ClipboardStore()
            if config.clipboard.cliAccess { history.load() }
            ctx.clipboard = { offset in
                if offset < history.items.count { return history.items[offset].text }
                return offset == 0 ? NSPasteboard.general.string(forType: .string) ?? "" : ""
            }
            do {
                print(try Placeholders.expand(s.text, name: s.name, context: ctx).text, terminator: "")
                return 0
            } catch Placeholders.ExpansionError.placeholder(let m) {
                return Output.fail(m)
            } catch {
                return Output.fail(error.localizedDescription)
            }
        case "add":
            guard let name = words.first, !name.isEmpty else { return Output.fail("usage: hop snippets add <name> [text] [--keyword=;k]") }
            let text = words.count > 1 ? words.dropFirst().joined(separator: " ") : stdinText() ?? ""
            guard !text.isEmpty else { return Output.fail("no text: pass it or pipe it in") }
            guard file.append(Snippet(name: name, keyword: a.option("keyword"), text: text)) else {
                return Output.fail("could not write \(file.url.path)")
            }
            print("added \(name) to \(file.url.path)")
            return 0
        default:
            if a.json {
                Output.json(file.snippets.map { ["name": $0.name, "keyword": $0.keyword ?? "", "text": $0.text] })
            } else {
                for s in file.snippets { print("\(s.name)\t\(s.keyword ?? "-")\t\(s.text.split(whereSeparator: \.isNewline).first ?? "")") }
            }
            return 0
        }
    }

    static func hotkeys(_ a: Args) async -> Int32 {
        let settings = AppSettings()
        let c = settings.data
        let services = Services(settings: settings, frecency: FrecencyStore(store: JSONStore(url: AppPaths.file("frecency.json"))),
                                apps: AppIndex())
        var commands = Registry.commands(services).map { (id: $0.id, title: $0.title) }
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

    static func clip(_ a: Args) async -> Int32 {
        let config = AppSettings().data.clipboard
        let store = ClipboardStore()
        store.load()
        var words = a.positional
        let sub = ["list", "show", "copy", "count"].contains(words.first ?? "") ? words.removeFirst() : "list"
        if sub == "count" {
            print(store.items.count)
            return 0
        }
        guard config.cliAccess else {
            return Output.fail("the clipboard history can hold anything you copied; set clipboard.cliAccess: true to read it here")
        }
        let query = words.joined(separator: " ")
        let found = store.items.filter { $0.matches(query) }
        func pick() -> ClipboardItem? {
            if let n = Int(query), n >= 1, n <= store.items.count { return store.items[n - 1] }
            return query.isEmpty ? store.items.first : found.first
        }
        switch sub {
        case "show":
            guard let item = pick() else { return Output.fail("no entry matches: \(query)") }
            let body = item.kind == .image ? store.imageURL(item)?.path ?? "" : item.text
            if a.json {
                Output.json(["kind": item.kind.rawValue, "text": body, "source": item.sourceName ?? "",
                             "copied": ISO8601DateFormatter().string(from: item.lastCopied), "pinned": item.pinned])
            } else {
                print(body)
            }
            return 0
        case "copy":
            guard let item = pick() else { return Output.fail("no entry matches: \(query)") }
            let pb = NSPasteboard.general
            pb.clearContents()
            switch item.kind {
            case .image: if let data = store.imageData(item) { pb.setData(data, forType: .png) }
            case .file: pb.writeObjects((item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
            default: pb.setString(item.text, forType: .string)
            }
            print("copied \(item.title)")
            return 0
        default:
            let limit = a.option("limit").flatMap(Int.init) ?? 20
            let list = Array(found.prefix(limit))
            if a.json {
                Output.json(list.map { i -> [String: Any] in
                    ["n": (store.items.firstIndex(of: i) ?? 0) + 1, "kind": i.kind.rawValue, "title": i.title,
                     "source": i.sourceName ?? "", "copied": ISO8601DateFormatter().string(from: i.lastCopied), "pinned": i.pinned]
                })
            } else {
                for i in list {
                    let n = (store.items.firstIndex(of: i) ?? 0) + 1
                    print("\(n)\t\(i.kind.rawValue)\t\(NoteStore.shortAge(i.lastCopied, now: Date()))\t\(i.title)")
                }
            }
            return 0
        }
    }

    /// Piped input, or nil when stdin is a terminal.
    static func shelf(_ a: Args) async -> Int32 {
        let raw = a.positional.isEmpty
            ? (stdinText() ?? "").split(whereSeparator: \.isNewline).map(String.init)
            : a.positional
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let paths = raw.map { URL(fileURLWithPath: $0.expandingTilde, relativeTo: cwd).standardizedFileURL.path }
        guard !paths.isEmpty else { return Output.fail("usage: hop shelf <path…>") }
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else { return Output.fail("no such file: \(missing.joined(separator: ", "))") }
        // Run through the /opt/homebrew/bin symlink, Bundle.main is not the app bundle.
        let id = Bundle.main.bundleIdentifier ?? "dev.hop.app"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else {
            return Output.fail("hop is not running")
        }
        DistributedNotificationCenter.default().postNotificationName(ShelfController.addNotification, object: nil,
                                                                     userInfo: ["paths": paths], deliverImmediately: true)
        return 0
    }

    private static func stdinText() -> String? {
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

        init(_ raw: [String]) {
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

import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the KeePass plugin.
extension KeePassPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["kp"], usage: [
                "kp dbs | search [query] | get <entry> [--field F] [--db NAME]   KeePassXC (unlocks per call)",
                "    --field: username (default), url, title, password, totp, notes",
                "    password, totp and notes need keepass.cliAccess: true; --password-stdin reads the",
                "    master password from stdin, otherwise keepass.password decides (keychain asks Touch ID)",
            ], run: CLI.keepass),
        ]
    }
}

extension CLI {
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

    static func masterPassword(_ db: HopConfig.KeePass.Database, _ a: Args) async throws -> String? {
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
}

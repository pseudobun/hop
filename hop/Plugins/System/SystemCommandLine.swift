import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the System plugin.
extension SystemPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["uninstall"], usage: [
                "uninstall <app> [--yes] [--json]    Remove an app and its ~/Library leftovers",
            ], run: CLI.uninstall),
            CLICommand(names: ["downloads"], usage: [
                "downloads clear [--yes] [--json]    Move everything in Downloads to the Trash",
            ], run: CLI.downloads),
            CLICommand(names: ["trash"], usage: [
                "trash count | empty [--yes]         Count or empty the Trash",
            ], run: CLI.trash),
            CLICommand(names: ["ps"], usage: [
                "ps [query] [--json]                 Running processes, busiest first",
            ], run: CLI.processes),
            CLICommand(names: ["kill"], usage: [
                "kill <pid|name> [--force] [--yes]   SIGTERM (or SIGKILL with --force) one process",
            ], run: CLI.killProcess),
        ]
    }
}

extension CLI {
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
}

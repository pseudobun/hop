import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Shelf plugin.
extension ShelfPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["shelf"], usage: [
                "shelf <path…>                       Put files on a shelf in the running hop (paths or stdin, one per line)",
            ], run: CLI.shelf),
        ]
    }
}

extension CLI {
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
        let id = AppPaths.bundleID
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else {
            return Output.fail("hop is not running")
        }
        let reply = HopIPC.send(.init(verb: .shelfAdd, paths: paths))
        return reply.ok ? 0 : Output.fail(reply.error ?? "hop did not answer")
    }
}

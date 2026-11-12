import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Files plugin.
extension FilesPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["files"], usage: [
                "files <query> [--content] [--json] [--limit=N]   Files by name (or by text with --content), via Spotlight",
            ], run: CLI.files),
        ]
    }
}

extension CLI {
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
}

import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Bookmarks plugin.
extension BookmarksPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["bookmarks"], usage: [
                "bookmarks [query] [--json]          Bookmarks from the config; bookmarks open <name>",
            ], run: CLI.bookmarks),
        ]
    }
}

extension CLI {
    /// `hop bookmarks [query] [--json]`, `hop bookmarks open <name>`.
    static func bookmarks(_ a: Args) async -> Int32 {
        let all = AppSettings().data.bookmarks.compactMap { b in BookmarkCommands.url(b.url).map { (b, $0) } }
        var words = a.positional
        let open = words.first == "open"
        if open || words.first == "list" { words.removeFirst() }
        let query = words.joined(separator: " ").lowercased()
        let matches = query.isEmpty ? all : all.filter { b, _ in
            b.name.lowercased().contains(query) || b.aliases.contains { $0.lowercased() == query }
        }
        if open {
            guard let (b, url) = matches.first(where: { $0.0.name.lowercased() == query || $0.0.aliases.map { $0.lowercased() }.contains(query) })
                ?? matches.first else { return Output.fail("no bookmark matching \(query)") }
            NSWorkspace.shared.open(url)
            print("opened \(b.name)")
            return 0
        }
        if a.json {
            Output.json(matches.map { b, url in ["name": b.name, "url": url.absoluteString, "aliases": b.aliases] })
        } else {
            for (b, url) in matches { print("\(b.name)\t\(url.absoluteString)") }
        }
        return 0
    }
}

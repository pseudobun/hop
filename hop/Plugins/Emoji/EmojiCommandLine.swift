import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Emoji plugin.
extension EmojiPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["emoji"], usage: [
                "emoji <query> [--limit=N] [--json]  Search emoji by name or slang (English, Slovenian)",
            ], run: CLI.emoji),
        ]
    }
}

extension CLI {
    /// `hop emoji <query> [--limit=N] [--json]`: the picker's search, slang and Slovenian included.
    static func emoji(_ a: Args) async -> Int32 {
        let query = a.positional.joined(separator: " ")
        guard !query.isEmpty else { return Output.fail("usage: hop emoji <query>") }
        guard let index = EmojiIndex.loadBlocking() else { return Output.fail("emoji data missing") }
        let tone = SkinTone(config: AppSettings().data.emoji.skinTone)
        let limit = a.option("limit").flatMap(Int.init) ?? 10
        let hits = index.search(query).prefix(limit).map { index.entries[$0] }
        if a.json {
            Output.json(hits.map { ["emoji": index.applying(tone, to: $0), "name": $0.name, "keywords": $0.keywords] })
        } else {
            for e in hits { print("\(index.applying(tone, to: e))\t\(e.name)") }
        }
        return hits.isEmpty ? 1 : 0
    }
}

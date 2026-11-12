import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Clipboard plugin.
extension ClipboardPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["clip"], usage: [
                "clip count                          How many entries the clipboard history holds",
                "clip [list] [query] [--json] [--limit=N]   Clipboard history, newest first (needs clipboard.cliAccess)",
                "clip show <n|query> [--json]        Print entry n (1 = newest) or the best match; images print their PNG path",
                "clip copy <n|query>                 Put an entry back on the clipboard",
            ], run: CLI.clip),
        ]
    }
}

extension CLI {
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
}

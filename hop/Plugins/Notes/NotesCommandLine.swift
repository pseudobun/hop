import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Notes plugin.
extension NotesPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["notes"], usage: [
                "notes [list] [query] [--json]       Notes in notes.folder (an Obsidian vault), newest first",
                "notes show <name>                   Print a note",
                "notes new <title> [text]            Create a note in notes.newNoteFolder (text or stdin)",
                "notes append <name> [text]          Append text (or stdin) to a note",
                "notes path                          Print the notes folder",
            ], run: CLI.notes),
        ]
    }
}

extension CLI {
    static func notes(_ a: Args) async -> Int32 {
        let config = AppSettings().data.notes
        let root = URL(fileURLWithPath: config.expandedFolder, isDirectory: true)
        var words = a.positional
        let sub = ["list", "show", "new", "append", "path"].contains(words.first ?? "") ? words.removeFirst() : "list"
        if sub == "path" {
            print(root.path)
            return 0
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Output.fail("no notes folder at \(root.path): set notes.folder in ~/.config/hop/config.json5")
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
}

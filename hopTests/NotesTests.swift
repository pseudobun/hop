import Foundation
import Testing
@testable import hop

struct MarkdownStylerTests {
    private func spans(_ text: String) -> [(String, MarkdownSpan)] {
        let ns = text as NSString
        return MarkdownStyler.spans(text).map { (ns.substring(with: $0.range), $0.span) }
    }

    private func has(_ text: String, _ piece: String, _ span: MarkdownSpan) -> Bool {
        spans(text).contains { $0.0 == piece && $0.1 == span }
    }

    @Test func headingsAndMarkers() {
        #expect(has("## Infra", "## Infra", .heading(2)))
        #expect(has("## Infra", "##", .marker))
        #expect(!spans("#tag line").contains { if case .heading = $0.1 { true } else { false } })
    }

    @Test func emphasisAndCode() {
        let line = "a **bold** and *it* and `**not bold**` ~~old~~ ==hi=="
        #expect(has(line, "**bold**", .bold))
        #expect(has(line, "*it*", .italic))
        #expect(has(line, "`**not bold**`", .code))
        #expect(!has(line, "**not bold**", .bold))
        #expect(has(line, "~~old~~", .strike))
        #expect(has(line, "==hi==", .highlight))
        #expect(!spans("snake_case_name and 2*3*4").contains { $0.1 == .italic })
    }

    @Test func links() {
        #expect(has("see [[olympus|the mini]] now", "olympus|the mini", .link("note:olympus|the mini")))
        #expect(has("[docs](https://x.dev/a)", "docs", .link("https://x.dev/a")))
        #expect(has("at https://pseudobun.dev/x.", "https://pseudobun.dev/x", .link("https://pseudobun.dev/x")))
    }

    @Test func tagsNotInsideURLsOrHeadings() {
        #expect(has("todo #inbox now", "#inbox", .tag))
        #expect(!spans("https://x.dev/#frag").contains { $0.1 == .tag })
        #expect(!spans("C# and a#b").contains { $0.1 == .tag })
    }

    @Test func tasks() {
        #expect(has("- [ ] buy", "[ ]", .task(done: false)))
        #expect(has("- [x] done", "[x]", .task(done: true)))
        #expect(has("- [x] done", " done", .doneText))
        #expect(has("  1. first", "  1. ", .marker))
    }

    @Test func frontmatterOnlyAtTop() {
        let doc = "---\ntitle: X\ntags: [a]\n---\n# X\n---\n"
        let s = spans(doc)
        #expect(s.filter { $0.1 == .frontmatter }.map(\.0) == ["---", "title: X", "tags: [a]", "---"])
        #expect(s.contains { $0.0 == "---" && $0.1 == .rule })
        #expect(s.contains { $0.0 == "# X" && $0.1 == .heading(1) })
    }

    @Test func fencedCodeIsNotMarkdown() {
        let doc = "```sh\n# not a heading\n**x**\n```\n# heading"
        let s = spans(doc)
        #expect(s.filter { $0.1 == .codeBlock }.count == 4)
        #expect(!s.contains { $0.1 == .bold })
        #expect(s.contains { $0.0 == "# heading" && $0.1 == .heading(1) })
    }
}

struct MarkdownEditingTests {
    @Test(arguments: zip(
        ["- a", "* [x] done", "  - [ ] task", "9. nine", "> - quoted", "1) x"],
        ["- ", "* [ ] ", "  - [ ] ", "10. ", "> - ", "2) "]))
    func continuesLists(line: String, prefix: String) {
        #expect(MarkdownEditing.continueList(line) == .insert(prefix))
    }

    @Test func endsEmptyItemAndIgnoresProse() {
        #expect(MarkdownEditing.continueList("- ") == .endList(bulletLength: 2))
        #expect(MarkdownEditing.continueList("  - [ ] ") == .endList(bulletLength: 8))
        #expect(MarkdownEditing.continueList("plain text") == nil)
        #expect(MarkdownEditing.continueList("-not a bullet") == nil)
    }

    @Test func togglesTasks() {
        #expect(MarkdownEditing.toggleTask("- [ ] a") == "- [x] a")
        #expect(MarkdownEditing.toggleTask("- [x] a") == "- [ ] a")
        #expect(MarkdownEditing.toggleTask("- a") == "- [ ] a")
        #expect(MarkdownEditing.toggleTask("  milk") == "  - [ ] milk")
    }

    @Test func togglesWraps() {
        #expect(MarkdownEditing.toggleWrap("x", marker: "**") == "**x**")
        #expect(MarkdownEditing.toggleWrap("**x**", marker: "**") == "x")
        #expect(MarkdownEditing.toggleWrap("", marker: "*") == "**")
    }
}

struct NoteStoreTests {
    private let date: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 23; c.hour = 14; c.minute = 5
        return Calendar.current.date(from: c)!
    }()

    @Test func scanSkipsHiddenFoldersAndListsPlaceholders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hop-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, age) in [("Home.md", 30.0), ("Infra/olympus.md", 10), (".obsidian/x.md", 0), ("raw/a.png", 0),
                            ("Inbox/.Evicted.md.icloud", 20), (".trash/old.md", 0), ("notes.txt", 0)] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let notes = try NoteStore.scan(root)
        #expect(notes.map(\.relativePath) == ["Infra/olympus.md", "Inbox/Evicted.md", "Home.md"])
        #expect(notes.map(\.isPlaceholder) == [false, true, false])
        #expect(notes[0].title == "olympus" && notes[0].folder == "Infra")
        #expect(throws: (any Error).self) { try NoteStore.scan(root.appending(path: "missing")) }
    }

    @Test func searchRanksTitlesThenText() {
        let notes = ["Infra/olympus.md", "Me/Bunny.md", "Gear/Printer.md"].enumerated().map { i, p in
            NoteFile(url: URL(fileURLWithPath: "/v/" + p), relativePath: p, modified: date.addingTimeInterval(Double(-i)))
        }
        let contents = ["Me/Bunny.md": "---\ntitle: Bunny\n---\nRuns olympus as a home server\n",
                        "Gear/Printer.md": "Bambu printer"]
        let hits = NoteStore.search(notes, query: "olympus", contents: contents)
        #expect(hits.map(\.note.title) == ["olympus", "Bunny"])
        #expect(hits[1].snippet == "Runs olympus as a home server")
        #expect(NoteStore.search(notes, query: "bambu PRINTER", contents: contents).map(\.note.title) == ["Printer"])
        #expect(NoteStore.search(notes, query: "", contents: [:]).count == 3)
        #expect(NoteStore.search(notes, query: "zzz", contents: contents).isEmpty)
    }

    @Test func fileNamesAndUniqueness() {
        #expect(NoteStore.fileName(for: "  a/b: c? [x] #1 ") == "a b c x 1")
        #expect(NoteStore.fileName(for: "...") == "Untitled")
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(NoteStore.uniqueURL(in: dir, title: "Olympus", taken: ["olympus", "olympus 2"]).lastPathComponent == "Olympus 3.md")
        #expect(NoteStore.uniqueURL(in: dir, title: "New", taken: []).lastPathComponent == "New.md")
    }

    @Test func templateFrontmatterAndBump() {
        let template = HopConfig.Notes().template
        let text = NoteStore.render(template: template, title: "Plan: Q4", date: date) + "body\n"
        #expect(text == "---\ntitle: \"Plan: Q4\"\ntags: [inbox]\ntype: note\nstatus: stub\nupdated: 2026-10-23\n---\n\nbody\n")
        #expect(NoteStore.render(template: "# {{title}} {{date}} {{time}}\n", title: "a: b", date: date) == "# a: b 2026-10-23 14:05\n")
        let bumped = NoteStore.bumpUpdated(text.replacingOccurrences(of: "2026-10-23", with: "2026-01-01") + "updated: keep\n",
                                           date: date)
        #expect(bumped.contains("updated: 2026-10-23\n---") && bumped.hasSuffix("updated: keep\n"))
        #expect(NoteStore.bumpUpdated("no frontmatter\nupdated: x\n", date: date) == "no frontmatter\nupdated: x\n")
        #expect(NoteStore.setTitle(text, "Plan Q4").hasPrefix("---\ntitle: Plan Q4\n"))
        #expect(NoteStore.frontmatterRange("---\n---\nx").map { "---\n---\nx"[$0] } == "---\n---\n")
        #expect(NoteStore.frontmatterRange("---\nunclosed") == nil)
    }

    @Test func yamlQuoting() {
        #expect(NoteStore.yamlScalar("olympus") == "olympus")
        #expect(NoteStore.yamlScalar("") == "\"\"")
        #expect(NoteStore.yamlScalar("yes") == "\"yes\"")
        #expect(NoteStore.yamlScalar("2026") == "\"2026\"")
        #expect(NoteStore.yamlScalar("say \"hi\": now") == "\"say \\\"hi\\\": now\"")
    }

    @Test func derivedTitles() {
        #expect(NoteStore.derivedTitle("---\ntitle: \"\"\n---\n\n## **Buy** milk\nmore") == "Buy milk")
        #expect(NoteStore.derivedTitle("- [ ] call [[Mojca]]") == "call Mojca")
        #expect(NoteStore.derivedTitle("\n  \n") == nil)
        #expect(NoteStore.derivedTitle(String(repeating: "word ", count: 30))?.count ?? 0 <= 60)
    }

    @Test func resolvesWikiLinks() {
        let notes = ["Infra/Machines/olympus.md", "Work/Lutra Labs.md"].map {
            NoteFile(url: URL(fileURLWithPath: "/v/" + $0), relativePath: $0, modified: date)
        }
        #expect(NoteStore.resolve(link: "olympus", in: notes)?.relativePath == "Infra/Machines/olympus.md")
        #expect(NoteStore.resolve(link: "Lutra Labs#LutraID", in: notes)?.title == "Lutra Labs")
        #expect(NoteStore.resolve(link: "lutra labs|LL", in: notes)?.title == "Lutra Labs")
        #expect(NoteStore.resolve(link: "Machines/olympus.md", in: notes)?.title == "olympus")
        #expect(NoteStore.resolve(link: "minsky", in: notes) == nil)
    }

    @Test func shortAges() {
        #expect(NoteStore.shortAge(date, now: date.addingTimeInterval(30)) == "now")
        #expect(NoteStore.shortAge(date, now: date.addingTimeInterval(5 * 60)) == "5m")
        #expect(NoteStore.shortAge(date, now: date.addingTimeInterval(3 * 3600)) == "3h")
        #expect(NoteStore.shortAge(date, now: date.addingTimeInterval(2 * 86_400)) == "2d")
        #expect(NoteStore.shortAge(date, now: date.addingTimeInterval(60 * 86_400)) == "Oct 23")
        #expect(NoteStore.shortAge(date, now: date.addingTimeInterval(400 * 86_400)) == "Oct 2026")
    }

    @Test func notesConfigDefaultsAndHotkey() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data("{ notes: { newNoteFolder: \"Capture\" } }".utf8))
        #expect(c.notes.newNoteFolder == "Capture" && c.notes.hotkey == "alt+." && c.notes.enabled)
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.notes == HopConfig.Notes())
        #expect(HotkeySpec.parse("alt+.") != nil)
        #expect(NotesCommands.display("alt+.") == "⌥.")
    }
}

struct MarkdownPreviewTests {
    @Test func stripsSyntaxForReading() {
        let source = "---\ntitle: X\n---\n## Today\n- [ ] buy **milk** at [[Shop|the shop]]\n- [x] done\n"
            + "> [!note] Read `this`\n1. one\n```sh\nls\n```\n---\n[site](https://x.dev) ==hi=="
        #expect(MarkdownPreview.plain(source)
            == "title: X\nToday\n• ☐ buy milk at the shop\n• ☑ done\nNOTE Read this\n1. one\nls\n────────\nsite hi")
    }

    @Test func taskBoxesPointBackToTheSource() {
        let source = "a\n- [ ] x"
        let tasks = MarkdownPreview.edits(source).compactMap { e -> Int? in
            if case .task(false, let at) = e.replacement { at } else { nil }
        }
        #expect(tasks == [4])
    }
}

struct NotePinsTests {
    private func hit(_ path: String) -> NoteHit {
        NoteHit(note: NoteFile(url: URL(fileURLWithPath: "/v/" + path), relativePath: path, modified: .distantPast))
    }

    @Test func pinnedComeFirstInPinOrderWithoutQuery() {
        let hits = ["a.md", "b.md", "c.md", "d.md"].map(hit)
        let out = NoteStore.pinnedFirst(hits, pinned: ["d.md", "b.md", "gone.md"], query: "")
        #expect(out.map(\.note.relativePath) == ["d.md", "b.md", "a.md", "c.md"])
        #expect(out.map(\.pinned) == [true, true, false, false])
    }

    @Test func searchKeepsRankButMarksPins() {
        let hits = ["a.md", "b.md", "c.md"].map(hit)
        let out = NoteStore.pinnedFirst(hits, pinned: ["c.md"], query: "x")
        #expect(out.map(\.note.relativePath) == ["a.md", "b.md", "c.md"])
        #expect(out.map(\.pinned) == [false, false, true])
    }

    @Test func nothingPinnedLeavesHitsAlone() {
        let hits = ["a.md", "b.md"].map(hit)
        #expect(NoteStore.pinnedFirst(hits, pinned: [], query: "") == hits)
    }
}

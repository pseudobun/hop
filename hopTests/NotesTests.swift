import AppKit
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
        #expect(has("see [[atlas|the mini]] now", "atlas|the mini", .link("note:atlas|the mini")))
        #expect(has("[docs](https://x.dev/a)", "docs", .link("https://x.dev/a")))
        #expect(has("at https://example.com/x.", "https://example.com/x", .link("https://example.com/x")))
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
        for (path, age) in [("Home.md", 30.0), ("Infra/atlas.md", 10), (".obsidian/x.md", 0), ("raw/a.png", 0),
                            ("Inbox/.Evicted.md.icloud", 20), (".trash/old.md", 0), ("notes.txt", 0)] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let notes = try NoteStore.scan(root)
        #expect(notes.map(\.relativePath) == ["Infra/atlas.md", "Inbox/Evicted.md", "Home.md"])
        #expect(notes.map(\.isPlaceholder) == [false, true, false])
        #expect(notes[0].title == "atlas" && notes[0].folder == "Infra")
        #expect(throws: (any Error).self) { try NoteStore.scan(root.appending(path: "missing")) }
    }

    @Test func searchRanksTitlesThenText() {
        let notes = ["Infra/atlas.md", "Me/Alex.md", "Gear/Printer.md"].enumerated().map { i, p in
            NoteFile(url: URL(fileURLWithPath: "/v/" + p), relativePath: p, modified: date.addingTimeInterval(Double(-i)))
        }
        let contents = ["Me/Alex.md": "---\ntitle: Alex\n---\nRuns atlas as a home server\n",
                        "Gear/Printer.md": "Bambu printer"]
        let hits = NoteStore.search(notes, query: "atlas", contents: contents)
        #expect(hits.map(\.note.title) == ["atlas", "Alex"])
        #expect(hits[1].snippet == "Runs atlas as a home server")
        #expect(NoteStore.search(notes, query: "bambu PRINTER", contents: contents).map(\.note.title) == ["Printer"])
        #expect(NoteStore.search(notes, query: "", contents: [:]).count == 3)
        #expect(NoteStore.search(notes, query: "zzz", contents: contents).isEmpty)
    }

    @Test func fileNamesAndUniqueness() {
        #expect(NoteStore.fileName(for: "  a/b: c? [x] #1 ") == "a b c x 1")
        #expect(NoteStore.fileName(for: "...") == "Untitled")
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(NoteStore.uniqueURL(in: dir, title: "Atlas", taken: ["atlas", "atlas 2"]).lastPathComponent == "Atlas 3.md")
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
        #expect(NoteStore.yamlScalar("atlas") == "atlas")
        #expect(NoteStore.yamlScalar("") == "\"\"")
        #expect(NoteStore.yamlScalar("yes") == "\"yes\"")
        #expect(NoteStore.yamlScalar("2026") == "\"2026\"")
        #expect(NoteStore.yamlScalar("say \"hi\": now") == "\"say \\\"hi\\\": now\"")
    }

    @Test func derivedTitles() {
        #expect(NoteStore.derivedTitle("---\ntitle: \"\"\n---\n\n## **Buy** milk\nmore") == "Buy milk")
        #expect(NoteStore.derivedTitle("- [ ] call [[Alex]]") == "call Alex")
        #expect(NoteStore.derivedTitle("\n  \n") == nil)
        #expect(NoteStore.derivedTitle(String(repeating: "word ", count: 30))?.count ?? 0 <= 60)
    }

    @Test func resolvesWikiLinks() {
        let notes = ["Infra/Machines/atlas.md", "Work/Acme Corp.md"].map {
            NoteFile(url: URL(fileURLWithPath: "/v/" + $0), relativePath: $0, modified: date)
        }
        #expect(NoteStore.resolve(link: "atlas", in: notes)?.relativePath == "Infra/Machines/atlas.md")
        #expect(NoteStore.resolve(link: "Acme Corp#Widgets", in: notes)?.title == "Acme Corp")
        #expect(NoteStore.resolve(link: "acme corp|AC", in: notes)?.title == "Acme Corp")
        #expect(NoteStore.resolve(link: "Machines/atlas.md", in: notes)?.title == "atlas")
        #expect(NoteStore.resolve(link: "nas", in: notes) == nil)
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

struct NoteSearchTests {
    private func notes(_ paths: [String]) -> [NoteFile] {
        paths.enumerated().map { i, p in
            NoteFile(url: URL(fileURLWithPath: "/v/" + p), relativePath: p, modified: Date(timeIntervalSince1970: Double(1000 - i)))
        }
    }

    @Test func parsesQuerySyntax() {
        let q = NoteQuery.parse(#""home server" -draft path:Infra #inbox tag:#hop word "unclosed phrase"#)
        #expect(q.terms == ["home server", "word", "unclosed phrase"])
        #expect(q.excluded == ["draft"])
        #expect(q.paths == ["Infra"])
        #expect(q.tags == ["inbox", "hop"])
        #expect(NoteQuery.parse("  ").isEmpty)
        #expect(NoteQuery.parse("- # ##x").terms == ["-", "#", "##x"])
    }

    @Test func filtersByPathTagAndExclusion() {
        let all = notes(["Infra/atlas.md", "Infra/nas.md", "Me/Alex.md", "Inbox/todo.md"])
        let contents = [
            "Infra/atlas.md": "---\ntags: [machine, infra]\n---\nMac mini server",
            "Infra/nas.md": "---\ntags:\n  - machine\n  - unraid\n---\nUnraid server, draft",
            "Me/Alex.md": "Runs the server #person",
            "Inbox/todo.md": "- [ ] server stuff #inbox/later",
        ]
        let titles = { (q: String) in NoteStore.search(all, query: q, contents: contents).map(\.note.title) }
        #expect(Set(titles("server")) == ["atlas", "nas", "Alex", "todo"])
        #expect(titles("server path:infra") == ["atlas", "nas"])
        #expect(titles("server -draft path:Infra") == ["atlas"])
        #expect(titles("#unraid") == ["nas"])
        #expect(Set(titles("tag:machine")) == ["atlas", "nas"])
        #expect(titles("#inbox") == ["todo"]) // nested tag inbox/later
        #expect(titles("#person server") == ["Alex"])
    }

    @Test func ranksTitlesThenRelevantText() {
        let all = notes(["Projects/hop.md", "Inbox/a.md", "Inbox/b.md", "Inbox/c.md"])
        let contents = [
            "Projects/hop.md": "launcher",
            "Inbox/a.md": "notes window once",
            "Inbox/b.md": "the notes window, notes window again, notes window",
            "Inbox/c.md": "---\ntitle: c\n---\nwindow of notes",
        ]
        let hits = NoteStore.search(all, query: "notes window", contents: contents)
        #expect(hits.map(\.note.title) == ["b", "a", "c"]) // phrase and count beat word-only matches
        #expect(hits[0].matches == 6 && hits[0].terms == ["notes", "window"])
        #expect(hits[0].snippet == "the notes window, notes window again, notes window")
        #expect(NoteStore.search(all, query: "hop", contents: contents).first?.note.title == "hop")
    }

    @Test func firstMatchPrefersTheBody() {
        let text = "---\ntitle: atlas\n---\nThe atlas box"
        let (count, location) = NoteStore.matchInfo(text, terms: ["atlas"])
        #expect(count == 2)
        #expect(location == (text as NSString).range(of: "atlas box").location)
        #expect(NoteStore.matchInfo("only: x\n", terms: ["zzz"]).location == nil)
    }

    @Test func tagsFromFrontmatterAndBody() {
        let text = "---\ntags: [Moc, \"infra\"]\naliases:\n  - x\n---\nSee #Home-Lab and https://x.dev/#frag and C# code"
        #expect(NoteStore.tags(text) == ["moc", "infra", "home-lab"])
        #expect(NoteStore.tags("---\ntags:\n  - a\n  - b/c\ntype: x\n---\n") == ["a", "b/c"])
    }

    @Test func snippetsAroundTheMatch() {
        let long = String(repeating: "lorem ", count: 30) + "needle " + String(repeating: "ipsum ", count: 30)
        let s = NoteStore.snippet(long, at: (long as NSString).range(of: "needle").location)
        #expect(s.hasPrefix("…") && s.hasSuffix("…") && s.contains("needle"))
        #expect(NoteStore.snippet("  - short line\nnext", at: 5) == "- short line")
    }
}

struct MarkdownTableTests {
    private func tables(_ source: String) -> [MarkdownTables.Table] {
        MarkdownTables.parse(source, spans: MarkdownStyler.spans(source))
    }

    @Test func parsesAlignmentAndUnevenRows() throws {
        let source = "Before\n\n| Name | Value | Status |\n| :--- | ---: | :---: |\n| Alex | 42 |\n| Hop | 7 | ok | ignored |\n\nAfter"
        let table = try #require(tables(source).first)
        #expect(table.alignments == [.left, .right, .center])
        #expect(table.rows == [["Name", "Value", "Status"], ["Alex", "42", ""], ["Hop", "7", "ok"]])
        #expect((source as NSString).substring(with: table.range).hasPrefix("| Name"))
        #expect(MarkdownPreview.plain(source) == "Before\n\nName\tValue\tStatus\nAlex\t42\t\nHop\t7\tok\n\nAfter")
    }

    @Test func preservesWikiAliasesAndEscapedPipes() throws {
        let source = #"""
        Note | Code
        --- | ---
        [[Shop|the shop]] | `a\|b`
        [[Other\|alias]] | x\|y
        """#
        let table = try #require(tables(source).first)
        #expect(table.rows[1] == ["[[Shop|the shop]]", "`a|b`"])
        #expect(table.rows[2] == ["[[Other|alias]]", "x|y"])
        #expect(MarkdownPreview.plain(source) == "Note\tCode\nthe shop\ta|b\nalias\tx|y")
    }

    @Test func ignoresCodeMetadataAndMalformedTables() {
        for source in ["```md\n| A | B |\n| --- | --- |\n```",
                       "~~~\n| A | B |\n| --- | --- |\n~~~",
                       "---\n| A | B |\n| --- | --- |\n---",
                       "A | B\n--- | nope", "A | B\n--- | --- | ---", "text | only"] {
            #expect(tables(source).isEmpty)
        }
    }

    @Test @MainActor func rendersNativeTableWithFormattingAndLinks() throws {
        let source = "😀 Intro\n\n| Name | Value |\n| :--- | ---: |\n| [[Shop|the shop]] | **42** |\n\n- [ ] after"
        let rendered = NotesPreviewView.render(source)
        #expect(!rendered.string.contains("|"))
        #expect(!rendered.string.contains("---"))
        let ns = rendered.string as NSString
        let header = ns.range(of: "Name")
        let body = ns.range(of: "the shop")
        let number = ns.range(of: "42")
        let headerStyle = try #require(rendered.attribute(.paragraphStyle, at: header.location, effectiveRange: nil) as? NSParagraphStyle)
        let bodyStyle = try #require(rendered.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle)
        let numberStyle = try #require(rendered.attribute(.paragraphStyle, at: number.location, effectiveRange: nil) as? NSParagraphStyle)
        let headerBlock = try #require(headerStyle.textBlocks.first as? NSTextTableBlock)
        let bodyBlock = try #require(bodyStyle.textBlocks.first as? NSTextTableBlock)
        #expect(headerBlock.table === bodyBlock.table)
        #expect(headerBlock.table.numberOfColumns == 2)
        #expect(bodyBlock.startingRow == 1 && bodyBlock.startingColumn == 0)
        #expect(numberStyle.alignment == .right)
        #expect(rendered.attribute(.hopLink, at: body.location, effectiveRange: nil) as? String == "note:Shop|the shop")
        let font = try #require(rendered.attribute(.font, at: number.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let task = ns.range(of: "\u{fffc}")
        #expect(rendered.attribute(.hopTaskSource, at: task.location, effectiveRange: nil) as? Int == (source as NSString).range(of: "[ ]").location)
        #expect(NotesPreviewView.make().textLayoutManager == nil)
    }
}

@MainActor
struct MarkdownTableLayoutTests {
    private func bodyBackground(_ view: NSTextView, at index: Int) -> NSColor? {
        let style = view.textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks.first?.backgroundColor
    }

    @Test func wrapsCellsAndKeepsFollowingTextOutsideTable() throws {
        let preview = NotesPreviewView.make()
        preview.frame = NSRect(x: 0, y: 0, width: 520, height: 800)
        preview.textContainer?.containerSize = NSSize(width: 468, height: CGFloat.greatestFiniteMagnitude)
        preview.show("""
        ## Table preview

        | Item | Description | Count |
        | :--- | :--- | ---: |
        | [[Shop|the shop]] | A longer description that should wrap across multiple lines inside its cell. | **42** |
        | `a\\|b` | Second row | 7 |

        After the table.
        """)
        let lm = try #require(preview.layoutManager)
        let container = try #require(preview.textContainer)
        lm.ensureLayout(for: container)
        let ns = preview.string as NSString
        func rect(_ text: String) -> NSRect {
            lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: ns.range(of: text), actualCharacterRange: nil), in: container)
        }
        #expect(rect("Description").minX > rect("Item").maxX)
        #expect(rect("Count").minX > rect("Description").maxX)
        #expect(rect("After the table.").minY > rect("Second row").maxY)
        let afterStyle = try #require(preview.textStorage?.attribute(.paragraphStyle, at: ns.range(of: "After").location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(afterStyle.textBlocks.isEmpty)
        #expect(lm.usedRect(for: container).maxX <= container.containerSize.width + 1)
        #expect(bodyBackground(preview, at: ns.range(of: "Second row").location)?.alphaComponent == 1)

    }
}

import AppKit
import Testing
@testable import hop

struct NotesOutlineTests {
    @Test func ignoresMetadataAndCodePreservesDuplicateAndUnicodeOffsets() {
        let source = "---\n# metadata\n---\n# Živjo 🐇\n```md\n## code\n```\n## Same\ntext\n### Same\n~~~\n# code too\n~~~\n"
        let headings = NoteHeading.parse(source)
        #expect(headings.map(\.title) == ["Živjo 🐇", "Same", "Same"])
        #expect(headings.map(\.level) == [1, 2, 3])
        #expect(headings.map { (source as NSString).substring(with: $0.range) } == ["# Živjo 🐇", "## Same", "### Same"])
        #expect(headings[1].range.location != headings[2].range.location)
        #expect(NoteHeading.parse("plain text\n#tag\n").isEmpty)
    }

    @Test func closingMarkersAndEmptyHeadings() {
        #expect(NoteHeading.parse("## Heading ###\n### \n#### C#\n").map(\.title) == ["Heading", "C#"])
    }

    @Test func previewAnchorsSurviveFormattingAndEarlierReplacements() {
        let source = "---\ntitle: Demo\n---\n# **First**\n- [ ] task\n| A | B |\n| --- | --- |\n| # fake | 🐇 |\n## [[Note|Second]]\nbody\n## Second\n"
        let headings = NoteHeading.parse(source)
        let rendered = NotesPreviewView.render(source)
        var anchors: [Int: Int] = [:]
        rendered.enumerateAttribute(.hopHeadingSource, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if let offset = value as? Int, anchors[offset] == nil { anchors[offset] = range.location }
        }
        #expect(Set(anchors.keys) == Set(headings.map(\.range.location)))
        for (heading, expected) in zip(headings, ["First", "Second", "Second"]) {
            guard let location = anchors[heading.range.location] else {
                Issue.record("Missing preview heading: \(heading.title)")
                continue
            }
            #expect((rendered.string as NSString).substring(from: location).hasPrefix(expected))
        }
    }
}

@Suite(.serialized)
struct NotesOutlineInteractionTests {
    @Test func jumpsInBothModesAndAdaptsToWindowWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults.standard
        let keys = ["NotesLastNote", "NotesPreview", "NotesSidebarHidden", "NSWindow Frame hop.notes"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "NotesPreview")
        defaults.set(false, forKey: "NotesSidebarHidden")
        let source = "# Overview\nA floating notebook, with a map of the page.\n\n"
            + String(repeating: "A paragraph with enough space to scroll through the document.\n\n", count: 12)
            + "## Assembly\nPrepare the workspace.\n\n### Prepare the base\nCheck the parts.\n\n"
            + String(repeating: "Follow the instructions carefully.\n\n", count: 14)
            + "## Checks\nEverything is ready.\n"
        try source.write(to: directory.appending(path: "Guide.md"), atomically: true, encoding: .utf8)
        let config = directory.appending(path: "config.json")
        let data = try JSONSerialization.data(withJSONObject: ["notes": ["folder": directory.path]])
        try data.write(to: config)
        let controller = NotesController(settings: AppSettings(url: config))
        defer { controller.hide() }
        controller.panel.setFrame(NSRect(x: 160, y: 160, width: 1000, height: 620), display: true)
        controller.show()
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try #require(controller.panel.contentView))
        let outline = try #require(views.compactMap { $0 as? NotesOutlineView }.first)
        let editor = try #require(views.compactMap { $0 as? NotesTextView }.first)
        let preview = try #require(views.compactMap { $0 as? NotesPreviewView }.first)
        let assembly = try #require(descendants(outline).compactMap { $0 as? NSButton }.first { $0.title == "Assembly" })
        #expect(!outline.isHidden)
        _ = assembly.sendAction(assembly.action, to: assembly.target)
        #expect(editor.selectedRange().location == NoteHeading.parse(source)[1].range.location)
        #expect(editor.visibleRect.minY > 0)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil, characters: "e",
            charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        #expect(controller.panel.keyHandler?(event) == true)
        // Command actions execute in a Task; allow the preview switch to complete.
        try await Task.sleep(for: .milliseconds(100))
        #expect(preview.enclosingScrollView?.isHidden == false)
        _ = assembly.sendAction(assembly.action, to: assembly.target)
        #expect(preview.visibleRect.minY > 0)
        #expect(assembly.contentTintColor == Theme.foreground)
        preview.scrollToBeginningOfDocument(nil)
        let overview = try #require(descendants(outline).compactMap { $0 as? NSButton }.first { $0.title == "Overview" })
        #expect(overview.contentTintColor == Theme.foreground)
        controller.panel.setFrame(NSRect(x: 160, y: 160, width: 600, height: 620), display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        #expect(outline.isHidden)
        controller.panel.setFrame(NSRect(x: 160, y: 160, width: 1000, height: 620), display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        #expect(!outline.isHidden)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        _ = assembly.sendAction(assembly.action, to: assembly.target)
        if let path = ProcessInfo.processInfo.environment["HOP_OUTLINE_SNAPSHOT"] {
            try await Task.sleep(for: .milliseconds(300))
            await DebugSnapshot.capture(controller.panel, to: path)
        }
    }
}

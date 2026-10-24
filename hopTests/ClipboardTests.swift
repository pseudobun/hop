import AppKit
import Foundation
import Testing
@testable import hop

struct ClipColorTests {
    @Test(arguments: zip(
        ["#7C5CFF", "#abc", "#11223380", "rgb(16, 185, 129)", "rgba(255,0,0,0.5)", "hsl(252, 100%, 68%)", "rgb(100% 0% 0%)"],
        ["#7C5CFF", "#AABBCC", "#11223380", "#10B981", "#FF000080", "#7C5CFF", "#FF0000"]))
    func parsesColours(text: String, hex: String) {
        #expect(ClipColor.parse(text)?.hex == hex)
    }

    @Test func rejectsNonColours() {
        for s in ["#zzz", "#12345", "rgb(300, 0, 0)", "hello", "#hashtag", "rgb(1,2)", ""] { #expect(ClipColor.parse(s) == nil, "\(s)") }
    }

    @Test func formatsRGBAndHSL() {
        let c = ClipColor.parse("#7C5CFF")!
        #expect(c.rgb == "rgb(124, 92, 255)")
        #expect(c.hsl == "hsl(252, 100%, 68%)")
        #expect(ClipColor.parse("#000")!.hsl == "hsl(0, 0%, 0%)")
    }
}

struct ClipboardClassifierTests {
    @Test func kinds() {
        #expect(ClipboardClassifier.kind(of: "https://github.com/pseudobun/hop") == .link)
        #expect(ClipboardClassifier.kind(of: "  mailto:you@example.com \n") == .link)
        #expect(ClipboardClassifier.kind(of: "#10B981") == .color)
        #expect(ClipboardClassifier.kind(of: "see https://x.dev now") == .text)
        #expect(ClipboardClassifier.kind(of: "file.txt") == .text)
        #expect(ClipboardClassifier.kind(of: "http://notahost") == .text)
    }

    @Test func presentations() {
        #expect(ClipboardClassifier.presentation(of: "## Plan\n- one\n- two") == .markdown)
        #expect(ClipboardClassifier.presentation(of: "Read the **docs** first") == .markdown)
        #expect(ClipboardClassifier.presentation(of: "func a() {\n    return 1\n}") == .code)
        #expect(ClipboardClassifier.presentation(of: "git push origin main") == .code)
        #expect(ClipboardClassifier.presentation(of: "Hvala za sestanek, pošljem predlog.") == .prose)
    }

    @Test func statsAndTitles() {
        #expect(TextStats("one two\nthree") == TextStats("one two\nthree"))
        let s = TextStats("one two\nthree")
        #expect(s.characters == 13 && s.words == 3 && s.lines == 2)
        let image = ClipboardItem(kind: .image, imageWidth: 10, imageHeight: 20, hash: "x")
        #expect(image.title == "Image (10×20)")
        let files = ClipboardItem(kind: .file, filePaths: ["/a/b.txt", "/a/c.txt"], hash: "y")
        #expect(files.title == "b.txt +1")
        #expect(ClipboardItem(kind: .text, text: "\n  first line\nsecond", hash: "z").title == "first line")
    }

    @Test func searchAndGroups() {
        let item = ClipboardItem(kind: .text, text: "ssh pseudobun@olympus", sourceName: "Ghostty", hash: "h")
        #expect(item.matches("olympus SSH") && item.matches("ghostty") && item.matches("text") && !item.matches("minsky"))
        let now = Date()
        #expect(ClipboardGroups.title(for: now.addingTimeInterval(-60), now: now) == "Today")
        #expect(ClipboardGroups.title(for: now.addingTimeInterval(-86_400 * 3), now: now) == "This Week")
        #expect(ClipboardGroups.title(for: now.addingTimeInterval(-86_400 * 60), now: now) == "Older")
    }
}

@MainActor
struct ClipboardStoreTests {
    private func temp() -> URL { FileManager.default.temporaryDirectory.appending(path: "hop-clip-\(UUID().uuidString)") }

    private func text(_ s: String, at date: Date = Date()) -> ClipboardItem {
        ClipboardItem(kind: .text, text: s, firstCopied: date, lastCopied: date, hash: ClipboardStore.fingerprint(.text, [Data(s.utf8)]))
    }

    @Test func dedupesAndPersistsPrivately() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(dir: dir)
        store.add(text("a"))
        store.add(text("b"))
        store.add(text("a"))
        #expect(store.items.map(\.text) == ["a", "b"])
        #expect(store.items[0].timesCopied == 2)
        store.add(ClipboardItem(kind: .image, imageWidth: 1, imageHeight: 1, hash: "img"), image: Data([1, 2, 3]))
        store.saveNow()
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "index.json").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let reloaded = ClipboardStore(dir: dir)
        reloaded.load()
        #expect(reloaded.items.map(\.kind) == [.image, .text, .text])
        #expect(reloaded.imageData(reloaded.items[0]) == Data([1, 2, 3]))
    }

    @Test func prunesUnpinnedByAgeAndCount() {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(dir: dir)
        let now = Date()
        store.add(text("old", at: now.addingTimeInterval(-86_400 * 40)))
        store.add(text("old pinned", at: now.addingTimeInterval(-86_400 * 50)))
        store.togglePin(store.items[0].id)
        for i in 0..<5 { store.add(text("new \(i)", at: now)) }
        store.prune(keepDays: 30, maxItems: 3, now: now)
        #expect(store.items.map(\.text) == ["new 4", "new 3", "new 2", "old pinned"])
        #expect(store.clear() == 3)
        #expect(store.items.map(\.text) == ["old pinned"])
    }

    @Test func unreadableHistoryIsSetAsideNotOverwritten() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appending(path: "index.json"))
        try Data([9]).write(to: dir.appending(path: "keep.png"))
        let store = ClipboardStore(dir: dir)
        store.load()
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "index.json.bad").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "keep.png").path))
    }

    @Test func decodesOlderEntriesLeniently() throws {
        let json = #"[{"kind":"link","text":"https://x.dev","hash":"h","lastCopied":"2026-10-20T10:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([ClipboardItem].self, from: Data(json.utf8))
        #expect(items.count == 1 && items[0].kind == .link && items[0].timesCopied == 1 && !items[0].pinned)
    }

    @Test func convertsTIFFToPNG() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let tiff = try #require(rep.tiffRepresentation)
        let (png, w, h) = try #require(ClipboardMonitor.png(tiff))
        #expect(w == 3 && h == 2 && png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func clipboardConfigDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data("{ clipboard: { keepDays: -1 } }".utf8))
        #expect(c.clipboard.keepDays == -1 && c.clipboard.hotkey == "shift+alt+c" && c.clipboard.enabled)
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.clipboard == HopConfig.Clipboard())
        #expect(HotkeySpec.parse("shift+alt+c") != nil)
        #expect(ClipboardMonitor.skipTypes.contains("org.nspasteboard.ConcealedType"))
    }
}

struct HotkeyBindingTests {
    @Test func looksUpByIdTitleOrBundle() {
        let map = ["system.emptyTrash": "hyper+t", "safari": "hyper+s", "app:com.apple.Notes": "hyper+n", "WireGuard": "hyper+w"]
        #expect(HotkeyLookup.binding(id: "system.emptyTrash", title: "Empty Trash", in: map) == "hyper+t")
        #expect(HotkeyLookup.binding(id: "app:com.apple.Safari", title: "Safari", bundleID: "com.apple.Safari", in: map) == "hyper+s")
        #expect(HotkeyLookup.binding(id: "app:com.apple.Notes", title: "Notes", bundleID: "com.apple.Notes", in: map) == "hyper+n")
        #expect(HotkeyLookup.binding(id: "wireguard.tunnels", title: "WireGuard", in: map) == "hyper+w")
        #expect(HotkeyLookup.binding(id: "hop.quit", title: "Quit hop", in: map) == nil)
    }

    @Test func configHotkeysSection() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data(#"{ hotkeys: { "Empty Trash": "hyper+t" } }"#.utf8))
        #expect(c.hotkeys == ["Empty Trash": "hyper+t"])
        #expect(try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8)).hotkeys.isEmpty)
        #expect(NotesCommands.display("hyper+t") == "✦T")
        #expect(HotkeySpec.parse("hyper+t") != nil && HotkeySpec.parse("hyper+") == nil)
    }
}

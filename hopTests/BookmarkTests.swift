import AppKit
import Testing
@testable import hop

struct BookmarkTests {
    @Test func decodesWithDefaults() throws {
        let c = try ConfigTests.decode("""
        { bookmarks: [
          { name: "Home Assistant", url: "http://192.168.1.50:8123", aliases: ["hass", "ha"], icon: "icons/ha.svg" },
          { name: "Docs", url: "docs.example.com" },
        ] }
        """)
        #expect(c.bookmarks.count == 2)
        #expect(c.bookmarks[0].aliases == ["hass", "ha"])
        #expect(c.bookmarks[1].icon.isEmpty && c.bookmarks[1].aliases.isEmpty)
        #expect(c.general.hotkey == "cmd+space")
    }

    @Test func urls() {
        #expect(BookmarkCommands.url("docs.example.com")?.absoluteString == "https://docs.example.com")
        #expect(BookmarkCommands.url("http://192.168.1.50:8123")?.port == 8123)
        #expect(BookmarkCommands.url("") == nil)
        #expect(BookmarkCommands.url("not a url") == nil)
        #expect(BookmarkCommands.display(URL(string: "http://192.168.1.50:8123/")!) == "192.168.1.50:8123")
        #expect(BookmarkCommands.display(URL(string: "https://dash.example.com/media?type=tv")!) == "dash.example.com/media?type=tv")
    }

    @Test func skipsBookmarksWithoutNameOrURL() {
        let dir = URL(fileURLWithPath: "/tmp")
        #expect(BookmarkCommands.item(for: .init(name: "", url: "https://a.com"), configDir: dir) == nil)
        #expect(BookmarkCommands.item(for: .init(name: "A", url: ""), configDir: dir) == nil)
        let item = BookmarkCommands.item(for: .init(name: "A", url: "https://a.com", aliases: ["x"]), configDir: dir)
        #expect(item?.aliases == ["x"])
        #expect(item?.subtitle == "a.com")
    }

    @Test func icons() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-bookmark-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "icons"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: dir.appending(path: "icons/ha.svg"))

        func icon(_ value: String) -> ItemIcon { BookmarkCommands.icon(.init(icon: value), configDir: dir) }
        guard case .imageFile(let path) = icon("icons/ha.svg") else { Issue.record("relative file"); return }
        #expect(path == dir.appending(path: "icons/ha.svg").path)
        guard case .tile("bookmark.fill", _) = icon("icons/missing.svg") else { Issue.record("missing file"); return }
        guard case .tile("house.fill", _) = icon("house.fill") else { Issue.record("symbol"); return }
        guard case .emoji("🏠") = icon("🏠") else { Issue.record("emoji"); return }
        guard case .tile("bookmark.fill", _) = icon("") else { Issue.record("empty"); return }
        guard case .tile("bookmark.fill", _) = icon("no such symbol") else { Issue.record("unknown"); return }
    }

    @Test func colors() {
        #expect(BookmarkCommands.color("#18bcf2") != nil)
        #expect(BookmarkCommands.color("18BCF2") != nil)
        #expect(BookmarkCommands.color("#18bcf") == nil)
        #expect(BookmarkCommands.color("") == nil)
    }

    @Test func aliasesRankFirst() {
        let candidates = [
            RankCandidate(id: "ha", title: "Home Assistant", alternateTitles: ["hass", "ha"], typeWeight: TypeWeight.command),
            RankCandidate(id: "hs", title: "Hammerspoon", typeWeight: TypeWeight.application),
            RankCandidate(id: "hb", title: "HandBrake", typeWeight: TypeWeight.application),
        ]
        for query in ["hass", "home ass", "home"] {
            let order = RootRanker.rank(candidates, query: SearchQuery(query), sensitivity: .high)
            #expect(candidates[order[0]].id == "ha", "\(query)")
        }
    }
}

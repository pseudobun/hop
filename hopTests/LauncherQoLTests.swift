import AppKit
import Testing
@testable import hop

@MainActor
struct LauncherQoLTests {
    // MARK: - Keep the last query

    @Test func reopenPolicy() {
        typealias B = LauncherBehavior
        // Root query lives keepQueryFor seconds.
        #expect(B.reopen(elapsed: 3, inSubMode: false, keepQueryFor: 10, popToRootSeconds: 90) == .restore)
        #expect(B.reopen(elapsed: 10, inSubMode: false, keepQueryFor: 10, popToRootSeconds: 90) == .restore)
        #expect(B.reopen(elapsed: 11, inSubMode: false, keepQueryFor: 10, popToRootSeconds: 90) == .clearQuery)
        // 0 turns it off.
        #expect(B.reopen(elapsed: 0, inSubMode: false, keepQueryFor: 0, popToRootSeconds: 90) == .clearQuery)
        // A sub-mode is kept until popToRootSeconds, whatever keepQueryFor says.
        #expect(B.reopen(elapsed: 60, inSubMode: true, keepQueryFor: 0, popToRootSeconds: 90) == .restore)
        #expect(B.reopen(elapsed: 91, inSubMode: true, keepQueryFor: 10, popToRootSeconds: 90) == .popToRoot)
        // popToRootSeconds caps a longer keepQueryFor.
        #expect(B.reopen(elapsed: 100, inSubMode: false, keepQueryFor: 300, popToRootSeconds: 90) == .popToRoot)
    }

    final class QueryMode: Mode {
        let title: String?
        let placeholder = ""
        init(title: String? = nil) { self.title = title }
        func sections(for query: String) -> [ResultSection] {
            [ResultSection(title: nil, items: ["a", "b", "c"].map { id in
                Item(id: id, title: query + id, actions: [
                    Action(title: "Open") { .stay },
                    Action(title: "Copy", shortcut: .cmd("c", .shift)) { .stay },
                ])
            })]
        }
    }

    private func key(_ launcher: LauncherController, _ code: UInt16, _ chars: String) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: launcher.panel.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        _ = launcher.panel.keyHandler?(e)
    }

    @Test func rootQueryAndRowComeBack() {
        let launcher = LauncherController(root: QueryMode())
        launcher.show()
        launcher.setQuery("x")
        key(launcher, 125, "\u{F701}")
        launcher.hide()
        launcher.show()
        #expect(launcher.query == "x")
        #expect(launcher.debugSelectedID == "b")
        launcher.hide()
    }

    @Test func rootQueryClearedWhenKeepIsOff() {
        let launcher = LauncherController(root: QueryMode())
        launcher.keepQueryFor = { 0 }
        launcher.show()
        launcher.setQuery("x")
        key(launcher, 125, "\u{F701}")
        launcher.hide()
        launcher.show()
        #expect(launcher.query.isEmpty)
        #expect(launcher.debugSelectedID == "a")
        launcher.hide()
    }

    @Test func subModeOutlivesKeepQuery() {
        let launcher = LauncherController(root: QueryMode())
        launcher.keepQueryFor = { 0 }
        launcher.show()
        launcher.push(QueryMode(title: "Sub"))
        launcher.setQuery("kp")
        launcher.hide()
        launcher.show()
        #expect(launcher.query == "kp")
        launcher.hide()
    }

    // MARK: - Actions from the keyboard

    @Test func tabDecisions() {
        typealias B = LauncherBehavior
        #expect(B.tab(completion: "~/Documents/", pushesMode: true, actionCount: 3) == .complete("~/Documents/"))
        #expect(B.tab(completion: nil, pushesMode: true, actionCount: 1) == .enterMode)
        #expect(B.tab(completion: nil, pushesMode: false, actionCount: 3) == .openActions)
        #expect(B.tab(completion: nil, pushesMode: false, actionCount: 1) == .nothing)
        #expect(B.tab(completion: nil, pushesMode: false, actionCount: 0) == .nothing)
    }

    @Test func rightArrowDecisions() {
        typealias B = LauncherBehavior
        #expect(B.rightArrowOpensActions(selection: NSRange(location: 3, length: 0), textLength: 3, actionCount: 2))
        #expect(B.rightArrowOpensActions(selection: NSRange(location: 0, length: 0), textLength: 0, actionCount: 2))
        // Caret inside the text, or text selected: → edits as usual.
        #expect(!B.rightArrowOpensActions(selection: NSRange(location: 1, length: 0), textLength: 3, actionCount: 2))
        #expect(!B.rightArrowOpensActions(selection: NSRange(location: 0, length: 3), textLength: 3, actionCount: 2))
        // Nothing beyond ↵ to show.
        #expect(!B.rightArrowOpensActions(selection: NSRange(location: 3, length: 0), textLength: 3, actionCount: 1))
    }

    @Test func tabAndArrowsOpenAndCloseThePanel() {
        let launcher = LauncherController(root: QueryMode())
        launcher.show()
        key(launcher, 48, "\t")
        #expect(launcher.debugActionPanelOpen)
        key(launcher, 123, "\u{F702}") // ←
        #expect(!launcher.debugActionPanelOpen)
        key(launcher, 124, "\u{F703}") // → on an empty query
        #expect(launcher.debugActionPanelOpen)
        key(launcher, 48, "\t")
        #expect(!launcher.debugActionPanelOpen)
        launcher.hide()
    }

    // MARK: - Fallbacks

    @Test func fallbackURLsAreEncoded() throws {
        let chatgpt = try #require(FallbackSearch.engine("chatgpt"))
        #expect(FallbackSearch.url(chatgpt, query: " what is 1+1 & why? ")?.absoluteString
            == "https://chatgpt.com/?q=what%20is%201%2B1%20%26%20why%3F")
        let google = try #require(FallbackSearch.engine("Google"))
        #expect(FallbackSearch.url(google, query: "čevapi #1")?.absoluteString
            == "https://www.google.com/search?q=%C4%8Devapi%20%231")
        let github = try #require(FallbackSearch.engine("github"))
        #expect(FallbackSearch.url(github, query: "lutralabs/hop")?.absoluteString == "https://github.com/search?q=lutralabs%2Fhop")
        let custom = try #require(FallbackSearch.engine("https://duckduckgo.com/?q={query}"))
        #expect(custom.title == "Search duckduckgo.com")
        #expect(FallbackSearch.url(custom, query: "a b")?.absoluteString == "https://duckduckgo.com/?q=a%20b")
        #expect(FallbackSearch.engine("bing") == nil)
        #expect(FallbackSearch.engine("https://example.com") == nil)
    }

    @Test func fallbackVisibility() {
        #expect(FallbackSearch.applies(to: "rust lifetimes"))
        #expect(!FallbackSearch.applies(to: ""))
        #expect(!FallbackSearch.applies(to: "   "))
        #expect(!FallbackSearch.applies(to: "~/Documents"))
        #expect(!FallbackSearch.applies(to: "/usr/local"))
        #expect(FallbackSearch.section(for: "", entries: ["chatgpt"]) == nil)
        #expect(FallbackSearch.section(for: "x", entries: []) == nil)
        #expect(FallbackSearch.section(for: "x", entries: ["bing"]) == nil)
        // Config order, ChatGPT first by default; duplicates and unknown ids dropped.
        let ids = FallbackSearch.section(for: "x", entries: HopConfig.General().fallbacks + ["google", "bing"])?.items.map(\.id)
        #expect(ids == ["fallback.chatgpt", "fallback.google", "fallback.github"])
        let first = FallbackSearch.section(for: "x", entries: ["chatgpt"])?.items.first
        #expect(first?.title == "Ask ChatGPT" && first?.tracksFrecency == false && first?.actions.count == 2)
    }

    // MARK: - Config

    @Test func configDefaultsAndOverrides() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let defaults = try decoder.decode(HopConfig.self, from: Data("{}".utf8)).general
        #expect(defaults.keepQueryFor == 10 && defaults.fallbacks == ["chatgpt", "google", "github"])
        let custom = try decoder.decode(HopConfig.self, from: Data("{general: {keepQueryFor: 0, fallbacks: ['google']}}".utf8)).general
        #expect(custom.keepQueryFor == 0 && custom.fallbacks == ["google"] && custom.popToRootSeconds == 90)
        // The template parses and keeps the defaults.
        #expect(try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8)).general == HopConfig.General())
    }
}

import Foundation
import Testing
@testable import hop

struct EmojiTests {
    /// Built once: the test host is hop.app, so emoji.json is in Bundle.main.
    nonisolated static let index: EmojiIndex = EmojiIndex.loadBlocking()!

    func top(_ query: String, _ n: Int = 6) -> [String] {
        Self.index.search(query).prefix(n).map { Self.index.entries[$0].emoji }
    }

    @Test func loadsTheFullSet() {
        #expect(Self.index.entries.count > 1800)
        #expect(Self.index.groups.first == "Smileys & Emotion" && Self.index.groups.last == "Flags")
        #expect(Self.index.entry(for: "❤") != nil && Self.index.entry(for: "❤️") == Self.index.entry(for: "❤"))
    }

    @Test func slangFindsIntent() {
        #expect(top("wtf", 4) == ["🤯", "😳", "🤬", "😱"])
        // No fuzzy noise after the slang matches ("white flag" has w, t, f).
        #expect(!top("wtf", 40).contains("🏳️"))
        #expect(Array(top("lol", 2)) == ["😂", "🤣"])
        #expect(top("rip", 2) == ["🪦", "💀"])
        #expect(top("gg").contains("👍") && top("gg").contains("🎉"))
        #expect(top("nice").prefix(3).contains("👍"))
        #expect(top("ship it").first == "🚀")
        #expect(top(":fire:").first == "🔥")
    }

    @Test func searchesSlovenian() {
        #expect(top("srce").first == "❤️")
        #expect(top("smeh").first == "😂")
        #expect(top("pivo").first == "🍺")
        // From CLDR sl.xml alone: "mačka" folds to "macka".
        #expect(top("mačka", 1) == ["🐈"] && top("macka", 1) == ["🐈"])
        #expect(top("mrtvaška glava", 1) == ["💀"])
    }

    @Test func searchesNamesAndKeywords() {
        #expect(top("fire").first == "🔥")
        #expect(top("thumbs").prefix(2).contains("👍") && top("thumbs").prefix(2).contains("👎"))
        #expect(top("thumbs up").first == "👍")
        #expect(top("thu").contains("👍"))
        #expect(top("slovenia").first == "🇸🇮")
        #expect(top("+1").first == "👍")
        // Fuzzy fallback on names.
        #expect(top("thmbsup", 10).contains("👍"))
        #expect(top("qqqqzzz").isEmpty && top("").isEmpty)
    }

    @Test func everySlangEmojiExists() {
        for (keys, emoji) in EmojiSlang.table {
            for e in emoji { #expect(Self.index.entry(for: String(e)) != nil, "\(keys): \(e)") }
        }
    }

    @Test func appliesSkinTones() {
        let idx = Self.index
        func toned(_ e: String, _ t: SkinTone) -> String { idx.applying(t, to: idx.entries[idx.entry(for: e)!]) }
        #expect(toned("👍", .medium) == "👍🏽")
        #expect(toned("👍", .none) == "👍")
        #expect(toned("☝️", .dark) == "☝🏿") // the FE0F goes
        #expect(toned("🧑‍🤝‍🧑", .light) == "🧑🏻‍🤝‍🧑🏻") // not the 🤝
        #expect(toned("🏃‍♂️", .mediumDark) == "🏃🏾‍♂️")
        #expect(toned("😂", .dark) == "😂")
        #expect(toned("👨‍👩‍👧", .dark) == "👨‍👩‍👧") // families have no toned form
        #expect(SkinTone(config: "medium-light") == .mediumLight && SkinTone(config: "mediumDark") == .mediumDark)
        #expect(SkinTone(config: "🏿") == .dark && SkinTone(config: "3") == .medium && SkinTone(config: "x") == .none)
    }

    @Test func modeAppliesToneAndOrdersRecent() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hop-emoji-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = EmojiUsage(store: JSONStore(url: url))
        let t = Date().addingTimeInterval(-3600)
        usage.record("🔥", now: t)
        usage.record("👍", now: t.addingTimeInterval(10))
        usage.record("🔥", now: t.addingTimeInterval(20))
        usage.record("🎉", now: t.addingTimeInterval(30))
        #expect(usage.recent(9) == ["🎉", "🔥", "👍"])
        #expect(usage.frequent(9, now: t) == ["🔥"])
        // Persisted and read back.
        #expect(EmojiUsage(store: JSONStore(url: url)).recent(2) == ["🎉", "🔥"])

        let mode = EmojiMode(usage: usage, skinTone: .medium, index: Self.index)
        let browse = mode.sections(for: "")
        #expect(browse.map(\.title) == ["Recently Used", "Frequently Used"] + Self.index.groups)
        let glyphs = browse[0].items.map { item -> String in
            if case .emoji(let e) = item.icon { e } else { "" }
        }
        #expect(glyphs == ["🎉", "🔥", "👍🏽"])
        // Use lifts an emoji among equals: 👍 and 👎 match "thumbs" alike.
        #expect(mode.sections(for: "thumbs")[0].items.first?.title == "Thumbs up")
        for _ in 0..<3 { usage.record("👎") }
        #expect(mode.sections(for: "thumbs")[0].items.first?.title == "Thumbs down")
        #expect(EmojiMode.codePoints("👍🏽") == "U+1F44D U+1F3FD" && EmojiMode.codePoints("❤️") == "U+2764")
    }

    @Test func configDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let config = try decoder.decode(HopConfig.self, from: Data("{emoji: {skinTone: \"dark\"}}".utf8))
        #expect(config.emoji.enabled && config.emoji.skinTone == "dark")
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.emoji == HopConfig.Emoji())
    }

    @Test func searchIsFast() {
        let queries = ["s", "sm", "smi", "smile", "face", "wtf", "thumbs up", "srce", "heart", "zzzzq", "c", "cat face", "flag"]
        let clock = ContinuousClock()
        _ = Self.index.search("warm up")
        let elapsed = clock.measure {
            for q in queries { _ = Self.index.search(q) }
        }
        let perQuery = elapsed / queries.count
        print("emoji search: \(perQuery) per query over \(Self.index.entries.count) emoji")
        // Release targets < 5 ms; the Debug test build runs unoptimised.
        #expect(perQuery < .milliseconds(25))

        let usage = EmojiUsage(store: JSONStore(url: FileManager.default.temporaryDirectory.appending(path: "hop-emoji-\(UUID().uuidString).json")))
        let mode = EmojiMode(usage: usage, skinTone: .none, index: Self.index)
        let browse = clock.measure { _ = mode.sections(for: "") }
        let load = clock.measure { _ = EmojiIndex.loadBlocking() }
        print("emoji browse sections: \(browse), index build: \(load)")
        #expect(browse < .milliseconds(100))
    }

    @Test func asksTheModelOnlyForPhrasesAndMisses() {
        #expect(!EmojiMode.wantsAI("fire", matches: 20))
        #expect(!EmojiMode.wantsAI("ok", matches: 0))
        #expect(!EmojiMode.wantsAI("deploy faila", matches: 3))
        #expect(EmojiMode.wantsAI("deploy faila", matches: 3, forced: true))
        #expect(EmojiMode.wantsAI("zxqv", matches: 0))
        #expect(EmojiMode.aiKey("  Ko Deploy   faila ") == "ko deploy faila")
    }

    @Test func openAIRequestAndReply() throws {
        let body = OpenAI.body(system: "s", user: "dober tek", model: "gpt-6-luna", reasoning: "none", maxTokens: 400, schema: EmojiAI.schema)
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["reasoning_effort"] as? String == "none" && body["temperature"] == nil)
        #expect(OpenAI.body(system: "s", user: "x", model: "m", reasoning: "", maxTokens: 10)["reasoning_effort"] == nil)
        #expect(OpenAI.errorMessage(Data(#"{"error":{"message":"The model is deprecated"}}"#.utf8)) == "The model is deprecated")
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(JSONSerialization.isValidJSONObject(body))
        let reply = #"{"choices":[{"message":{"role":"assistant","content":"{\"emoji\":[\"🍽️\",\"😋\"]}"}}]}"#
        let content = try #require(OpenAI.content(Data(reply.utf8)))
        #expect(EmojiAI.parse(content) == ["🍽️", "😋"])
        #expect(OpenAI.content(Data("{}".utf8)) == nil)
        // Model picks map to index entries even without the variation selector.
        #expect(Self.index.entry(for: "🍽") != nil || Self.index.entry(for: "🍽️") != nil)
    }

    @Test func slovenianEndingsAndSynonyms() {
        #expect(top("povit srček", 3).contains("❤️‍🩹"))
        #expect(top("srček", 4).contains("❤️"))
        #expect(EmojiIndex.stem(Array("srcek".utf8)).map { String(decoding: $0, as: UTF8.self) } == "src")
        #expect(EmojiIndex.stem(Array("ok".utf8)) == nil)
    }
}

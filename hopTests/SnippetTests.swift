import CoreGraphics
import Foundation
import Testing
@testable import hop

/// Raycast's placeholder parser, checked against the golden vectors from raycast-re
/// (snippet consumer; quicklink and AI cases do not apply to hop).
nonisolated struct PlaceholderGoldenTests {
    static let snippets = [Snippet(name: "Sig", text: "Best, {clipboard}"), Snippet(name: "Bad", text: "x {argument}")]

    static var cases: [[String: Any]] {
        (Fixtures.placeholders["cases"] as! [[String: Any]]).filter { $0["consumer"] as? String == "snippet" }
    }

    /// The golden JSON shape for one parsed placeholder.
    static func encode(_ p: ParsedPlaceholder) -> [String: Any] {
        var out: [String: Any] = ["range": ["start": p.start, "end": p.end]]
        if let e = p.error { out["error"] = e; return out }
        var v: [String: Any] = [:]
        if !p.modifiers.isEmpty { v["modifiers"] = p.modifiers }
        switch p.value! {
        case .clipboard(let offset): v["type"] = "clipboard"; v["offset"] = offset
        case .uuid: v["type"] = "uuid"
        case .cursor: v["type"] = "cursor"
        case .calculator(let e): v["type"] = "calculator"; v["expression"] = e
        case .snippet(let n):
            let s = snippets.first { $0.name == n }!
            v["type"] = "snippet"; v["snippet"] = ["id": n == "Sig" ? "s1" : "s2", "title": s.name, "text": s.text]
        case .date(let unit, let format, let locale, let offsets):
            v["type"] = "date"; v["unit"] = unit.rawValue
            if let format { v["format"] = format }
            if let locale { v["locale"] = locale }
            v["dateModifiers"] = offsets.map { ["duration": String($0.unit), "difference": $0.amount] }
        case .argument(let position, let name, let def, let options):
            v["type"] = "argument"; v["position"] = position
            if let name { v["name"] = name }
            if let def { v["defaultValue"] = def }
            if let options { v["options"] = options.map { ["value": $0] } }
        }
        out["value"] = v
        return out
    }

    @Test(arguments: 0..<cases.count)
    func matchesRaycast(_ i: Int) throws {
        let c = Self.cases[i]
        let text = c["text"] as! String
        let expected = c["results"] as! [[String: Any]]
        let got = Placeholders.parse(text, snippets: Self.snippets).map(Self.encode)
        let a = try JSONSerialization.data(withJSONObject: got, options: .sortedKeys)
        let b = try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)
        #expect(String(decoding: a, as: UTF8.self) == String(decoding: b, as: UTF8.self), "\(text)")
    }
}

struct PlaceholderExpansionTests {
    private func expand(_ text: String, args: [String] = [], snippets: [Snippet] = [], clip: String = "  Hello  ") throws -> Placeholders.Expansion {
        var ctx = Placeholders.Context()
        ctx.clipboard = { $0 == 0 ? clip : "older" }
        ctx.arguments = args
        ctx.snippets = snippets
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 24; c.hour = 9; c.minute = 5
        ctx.now = Calendar.current.date(from: c)!
        ctx.locale = Locale(identifier: "en_US")
        ctx.calculate = { (try? Calculator.evaluate($0)).map { Calculator.format($0, locale: Locale(identifier: "en_US_POSIX")) } }
        return try Placeholders.expand(text, context: ctx)
    }

    @Test func modifiersAndClipboard() throws {
        #expect(try expand("<{clipboard | trim | uppercase}>").text == "<HELLO>")
        #expect(try expand("{clipboard offset=1}").text == "older")
        #expect(try expand("q={clipboard|trim|percent-encode}").text == "q=Hello")
        #expect(try expand("{clipboard|trim|json-stringify}").text == "\"Hello\"")
    }

    @Test func datesWithFormatsAndOffsets() throws {
        #expect(try expand(#"{date format="yyyy-MM-dd"}"#).text == "2026-10-24")
        #expect(try expand(#"{date format="dd.MM.YYYY" offset="+1d -2h"}"#).text == "25.10.2026")
        #expect(try expand(#"{date "dd.MM." +3d}"#).text == "27.10.")
        #expect(try expand("{day}").text == "Saturday")
        #expect(try expand("{date}").text == "Oct 24, 2026")
    }

    @Test func cursorArgumentsSnippetsCalculator() throws {
        let e = try expand("Hi {cursor}, see you {argument name=\"when\" default=\"soon\"}")
        #expect(e.text == "Hi , see you soon")
        #expect(e.charactersAfterCursor == 14)
        #expect(try expand("{argument name=x}/{argument name=x}/{argument}", args: ["a", "b"]).text == "a/a/b")
        #expect(try expand("{snippet name=\"Sig\"}", snippets: [Snippet(name: "Sig", text: "Best, {clipboard|trim}")]).text == "Best, Hello")
        #expect(try expand("{calculator expression=\"6*7\"}").text == "42")
        #expect(try expand("{uuid}").text.count == 36)
        #expect(throws: Placeholders.ExpansionError.placeholder("Unknown \"foo\" placeholder")) { try expand("{foo}") }
        #expect(try expand("plain {not a placeholder").text == "plain {not a placeholder")
    }

    @Test func snippetArguments() {
        let s = Snippet(name: "Mail", text: "Hi {argument name=\"who\" default=\"you\"}, {argument name=\"lang\" options=\"en, sl\"} {argument name=\"who\"}")
        let args = s.arguments
        #expect(args.count == 2)
        #expect(args[0].name == "who" && args[0].defaultValue == "you")
        #expect(args[1].options == ["en", "sl"])
    }
}

struct SnippetFileAndMatcherTests {
    @Test func decodesTheTemplateAndAppends() throws {
        let snippets = try SnippetsFile.decode(Data(SnippetsFile.template.utf8))
        #expect(snippets.map(\.name) == ["Email", "Today", "Signature"])
        #expect(snippets[0].keyword == ";mail" && snippets[2].keyword == nil && snippets[2].text == "Lp,\nUrban")
        let appended = try #require(SnippetsFile.appending(Snippet(name: "Q \"x\"", keyword: ";q", text: "a\nb"), to: SnippetsFile.template))
        let again = try SnippetsFile.decode(Data(appended.utf8))
        #expect(again.count == 4 && again[3] == Snippet(name: "Q \"x\"", keyword: ";q", text: "a\nb"))
        // A file whose last entry has no trailing comma still gets one.
        let noComma = "[\n  { name: \"A\", text: \"a\" }\n]\n"
        let fixed = try #require(SnippetsFile.appending(Snippet(name: "B", text: "b"), to: noComma))
        #expect(try SnippetsFile.decode(Data(fixed.utf8)).map(\.name) == ["A", "B"])
    }

    @Test func matchesKeywordsAtWordBoundaries() {
        let keys = [(keyword: ";mail", index: 0), (keyword: "addr", index: 1), (keyword: ";m", index: 2)]
        #expect(SnippetMatcher.match("send to ;mail", keywords: keys, withinWords: false)?.index == 0) // longest wins
        #expect(SnippetMatcher.match("x;mail", keywords: keys, withinWords: false)?.index == 0) // symbol keywords: anywhere
        #expect(SnippetMatcher.match("my addr", keywords: keys, withinWords: false)?.index == 1)
        #expect(SnippetMatcher.match("myaddr", keywords: keys, withinWords: false) == nil)
        #expect(SnippetMatcher.match("myaddr", keywords: keys, withinWords: true)?.index == 1)
        #expect(SnippetMatcher.match("nothing", keywords: keys, withinWords: false) == nil)
    }

    @Test func optionListQuirks() {
        #expect(Placeholders.parseOptionList("en, sl, de") == ["en", "sl", "de"])
        #expect(Placeholders.parseOptionList("a\\, b, c:d") == [", b", "c:d"])
        #expect(Placeholders.parseOptionList("ab\\, c, d") == ["ab, c", "d"])
        #expect(Placeholders.parseOptionList("  ") == [])
        #expect(Placeholders.parseOptionList("") == nil)
        #expect(Placeholders.parseOptionList("a\\") == nil)
    }

    @Test func snippetsConfigDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(c.snippets == HopConfig.Snippets())
        #expect(c.snippets.expand && !c.snippets.expandWithinWords)
    }
}

struct SnippetTapStateTests {
    nonisolated private final class Matches: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// The event tap calls the state on its own thread; main-actor code there traps.
    @Test func handlesTypingOffTheMainThread() async {
        let state = SnippetTapState()
        state.setKeywords([";em"])
        let matches = Matches()
        state.onMatch = { @Sendable in matches.add($0) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread { @Sendable in
                for ch in ["x", ";", "e", "m"] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
                    let units = Array(ch.utf16)
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    state.handle(.keyDown, e)
                }
                done.resume()
            }.start()
        }
        #expect(matches.all == ["x;em"])
    }
}

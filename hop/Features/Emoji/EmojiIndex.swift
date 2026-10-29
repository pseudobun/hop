import CoreText
import Foundation
import os

/// Skin tone applied to emoji that take one (`emoji.skinTone`).
nonisolated enum SkinTone: Int, Sendable, CaseIterable {
    case none, light, mediumLight, medium, mediumDark, dark

    /// Lenient: "medium-light", "mediumLight", "medium_light", "3", or the modifier itself; else none.
    init(config: String) {
        let key = config.lowercased().filter { $0.isLetter || $0.isNumber }
        let modifiers: [String] = ["🏻", "🏼", "🏽", "🏾", "🏿"]
        if let i = modifiers.firstIndex(of: config.trimmingCharacters(in: .whitespaces)) {
            self = Self(rawValue: i + 1)!
            return
        }
        self = switch key {
        case "light", "1": .light
        case "mediumlight", "2": .mediumLight
        case "medium", "3": .medium
        case "mediumdark", "4": .mediumDark
        case "dark", "5": .dark
        default: .none
        }
    }

    /// U+1F3FB…U+1F3FF.
    var modifier: Unicode.Scalar? { self == .none ? nil : Unicode.Scalar(0x1F3FA + UInt32(rawValue)) }
}

/// The emoji set and its search index. Built once, off the main thread, from the bundled
/// `emoji.json` (Unicode emoji-test order and groups, CLDR English and Slovenian names and
/// keywords; see scripts/gen-emoji.py), narrowed to what this macOS can draw using
/// CoreEmoji's AppleName.strings, whose names also join the keywords.
nonisolated final class EmojiIndex: Sendable {
    struct Entry: Sendable {
        let emoji: String
        /// CLDR English name, lower case ("face with tears of joy").
        let name: String
        let group: Int
        let takesSkinTone: Bool
        /// English keywords, for the detail line.
        let keywords: [String]
    }

    let entries: [Entry]
    let groups: [String]
    private let modifierBases: Set<UInt32>
    /// Sorted unique search tokens (folded ASCII bytes) and, parallel, who has them.
    private let tokens: [[UInt8]]
    private let postings: [[Posting]]
    /// Folded English and Slovenian names, for whole-name matches.
    private let names: [[UInt8]]
    private let localNames: [[UInt8]]
    private let fuzzyNames: [FuzzyTarget]
    /// Folded slang phrase → entries, best first.
    private let slang: [(key: [UInt8], entries: [Int])]
    private let byEmoji: [String: Int]

    private struct Posting: Sendable {
        let entry: Int32
        let field: Field
    }

    private enum Field: UInt8, Sendable {
        case nameFirst, name, keyword, other
    }

    static let appleNamesURL = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources/en.lproj/AppleName.strings")

    // MARK: - Loading

    private static let queue = DispatchQueue(label: "hop.emoji-index", qos: .userInitiated)

    /// Builds the index on a dispatch queue (it is blocking work: JSON, a plist, folding).
    static func load(bundle: Bundle = .main) async -> EmojiIndex? {
        await withCheckedContinuation { done in queue.async { done.resume(returning: loadBlocking(bundle: bundle)) } }
    }

    static func loadBlocking(bundle: Bundle = .main, appleNames: URL? = appleNamesURL) -> EmojiIndex? {
        guard let url = bundle.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            Log.app.error("emoji: emoji.json missing or unreadable")
            return nil
        }
        let apple = appleNames.flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        return EmojiIndex(file: file, appleNames: apple)
    }

    private struct File: Decodable {
        let groups: [String]
        let bases: [UInt32]
        let e: [Row]

        struct Row: Decodable {
            let emoji: String, name: String, group: Int, keywords: String, slovenian: String, tones: Int

            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                emoji = try c.decode(String.self)
                name = try c.decode(String.self)
                group = try c.decode(Int.self)
                keywords = try c.decode(String.self)
                slovenian = try c.decode(String.self)
                tones = try c.decode(Int.self)
            }
        }
    }

    private init(file: File, appleNames: [String: String]) {
        groups = file.groups
        modifierBases = Set(file.bases)
        var apple: [String: String] = [:]
        for (k, v) in appleNames { apple[Self.key(k)] = v }
        // Fewer names than this means a different file format: show everything.
        let filter = apple.count > 1000
        let emojiFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)

        var entries: [Entry] = []
        var tokenMap: [[UInt8]: [Posting]] = [:]
        var names: [[UInt8]] = []
        var localNames: [[UInt8]] = []
        var fuzzy: [FuzzyTarget] = []
        var byEmoji: [String: Int] = [:]
        for row in file.e {
            let appleName = apple[Self.key(row.emoji)]
            // Not in AppleName.strings: newer than this macOS, unless the font has it (♀️).
            if filter && appleName == nil && !Self.fontHasGlyph(emojiFont, row.emoji) { continue }
            let i = Int32(entries.count)
            let keywords = row.keywords.split(separator: "|").map(String.init)
            entries.append(Entry(emoji: row.emoji, name: row.name, group: row.group, takesSkinTone: row.tones == 1,
                                 keywords: keywords))
            byEmoji[Self.key(row.emoji)] = Int(i)
            // The Slovenian name counts as a name: "mačka" is 🐈, before the cat faces.
            let slovenian = row.slovenian.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let localName = slovenian.first.map(String.init) ?? ""
            names.append(Self.fold(row.name))
            localNames.append(Self.fold(localName))
            fuzzy.append(FuzzyTarget(row.name))
            var seen = Set<[UInt8]>()
            func add(_ text: String, _ field: Field) {
                for (n, t) in Self.words(Self.fold(text)).enumerated() where seen.insert(t).inserted {
                    tokenMap[t, default: []].append(Posting(entry: i, field: field == .name && n == 0 ? .nameFirst : field))
                }
            }
            add(row.name, .name)
            add(localName, .name)
            add(row.keywords, .keyword)
            if slovenian.count > 1 { add(String(slovenian[1]), .other) }
            if let appleName { add(appleName, .other) }
        }
        let sorted = tokenMap.keys.sorted { $0.lexicographicallyPrecedes($1) }
        tokens = sorted
        postings = sorted.map { tokenMap[$0]! }
        self.entries = entries
        self.names = names
        self.localNames = localNames
        fuzzyNames = fuzzy
        self.byEmoji = byEmoji
        var slang: [(key: [UInt8], entries: [Int])] = []
        for (keys, emoji) in EmojiSlang.table {
            let hits = emoji.compactMap { byEmoji[Self.key(String($0))] }
            for k in keys.split(separator: "|") { slang.append((Self.fold(String(k)), hits)) }
        }
        self.slang = slang
    }

    private static func fontHasGlyph(_ font: CTFont, _ emoji: String) -> Bool {
        let utf16 = Array(emoji.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) && glyphs[0] != 0
    }

    // MARK: - Text

    /// Lookup key: the emoji without variation selectors.
    static func key(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
    }

    /// Lower-cased, accents removed (č → c), as bytes.
    static func fold(_ s: String) -> [UInt8] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased().utf8)
    }

    /// Splits on anything but letters, digits and "+" (for "+1"); "’" and "'" join ("i’m" → "im").
    static func words(_ folded: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var cur: [UInt8] = []
        var i = 0
        while i < folded.count {
            let b = folded[i]
            if b == 0x27 { i += 1; continue }
            if b == 0xE2, i + 2 < folded.count, folded[i + 1] == 0x80, folded[i + 2] == 0x99 { i += 3; continue } // ’
            let isWord = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b >= 0x80
            if isWord { cur.append(b) } else if !cur.isEmpty { out.append(cur); cur = [] }
            i += 1
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: - Skin tone

    /// `emoji` in `tone`: the modifier goes after each modifier base (dropping its U+FE0F),
    /// but not after one between two ZWJs (the 🤝 in 🧑‍🤝‍🧑).
    func applying(_ tone: SkinTone, to entry: Entry) -> String {
        guard entry.takesSkinTone, let modifier = tone.modifier else { return entry.emoji }
        return Self.applying(modifier, to: entry.emoji, bases: modifierBases)
    }

    static func applying(_ modifier: Unicode.Scalar, to emoji: String, bases: Set<UInt32>) -> String {
        let scalars = Array(emoji.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            out.append(scalars[i])
            let inside = i > 0 && i < scalars.count - 1 && scalars[i - 1].value == 0x200D && scalars[i + 1].value == 0x200D
            if bases.contains(scalars[i].value) && !inside {
                out.append(modifier)
                if i + 1 < scalars.count && scalars[i + 1].value == 0xFE0F { i += 1 }
            }
            i += 1
        }
        return String(out)
    }

    func entry(for emoji: String) -> Int? { byEmoji[Self.key(emoji)] }

    // MARK: - Search

    /// Entries matching `query`, best first: slang/intent phrases, whole-name matches, name
    /// words, keywords (English, Slovenian, Apple), then fuzzy names when little matched.
    /// `boost` adds a usage score per entry.
    func search(_ query: String, limit: Int = 300, boost: (Int) -> Double = { _ in 0 }) -> [Int] {
        let q = Self.fold(query.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces)))
        let qWords = Self.words(q)
        guard !qWords.isEmpty else { return [] }
        let n = entries.count
        var score = [Int32](repeating: 0, count: n)
        var matchedWords = [Int](repeating: 0, count: n)
        var wordBest = [Int32](repeating: 0, count: n)
        var touched: [Int] = []
        for (wi, w) in qWords.enumerated() {
            touched.removeAll(keepingCapacity: true)
            var t = lowerBound(w)
            while t < tokens.count, tokens[t].starts(with: w) {
                let exact = tokens[t].count == w.count
                // A prefix scores by how much of the word it covers.
                let cover = Int32(w.count * 20 / tokens[t].count)
                for p in postings[t] {
                    let s: Int32 = switch p.field {
                    case .nameFirst: exact ? 110 : 50 + cover
                    case .name: exact ? 100 : 45 + cover
                    case .keyword: exact ? 75 : 30 + cover
                    case .other: exact ? 65 : 25 + cover
                    }
                    let e = Int(p.entry)
                    if wordBest[e] == 0 { touched.append(e) }
                    if s > wordBest[e] { wordBest[e] = s }
                }
                t += 1
            }
            for e in touched {
                if matchedWords[e] == wi {
                    matchedWords[e] += 1
                    score[e] += wordBest[e]
                }
                wordBest[e] = 0
            }
        }
        var total = [Int32](repeating: 0, count: n)
        var results: [Int] = []
        for e in 0..<n where matchedWords[e] == qWords.count {
            let whole = names[e] == q || localNames[e] == q
            total[e] = score[e] + (whole ? 300 : names[e].starts(with: q) || localNames[e].starts(with: q) ? 120 : 0)
            results.append(e)
        }
        // Slang and intent: "wtf", "ship it", "srce".
        var slangHit = false
        for s in slang {
            let bonus: Int32
            if s.key == q { bonus = 1000; slangHit = true } else if q.count >= 3 && s.key.starts(with: q) { bonus = 220 } else { continue }
            for (rank, e) in s.entries.enumerated() {
                if total[e] == 0 { results.append(e) }
                total[e] += max(10, bonus - Int32(rank * 12))
            }
        }
        // Fuzzy only for longer typos ("thmbsup"); short queries and slang hits match letters
        // scattered through unrelated names ("wtf" → "white flag").
        if results.count < 12 && q.count >= 4 && !slangHit {
            let utf16 = Array(String(decoding: q, as: UTF8.self).utf16)
            for e in 0..<n where total[e] == 0 {
                if case .scored(let s, _) = FuzzyScorer.score(fuzzyNames[e], utf16), s > 0 {
                    total[e] = Int32(min(40, s))
                    results.append(e)
                }
            }
        }
        var ranked = results.map { e in (e, Double(total[e]) + min(50, 8 * log(max(1, boost(e))))) }
        ranked.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return ranked.prefix(limit).map(\.0)
    }

    private func lowerBound(_ w: [UInt8]) -> Int {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].lexicographicallyPrecedes(w) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

import Foundation
import Testing
@testable import hop

nonisolated struct ScorerCase: CustomTestStringConvertible, Sendable {
    let query: String
    let text: String
    let transliteratedQuery: String
    let expected: FuzzyResult
    let low: Bool, medium: Bool, high: Bool
    let titlePrefix: String
    let wholeWord: Bool
    let wholeWordFloor: Double

    var testDescription: String { "\"\(query)\" / \"\(text)\"" }

    /// Raycast's stale-row quirk cases, with the expectations of the fixed scorer.
    static let fixedQuirks: [String: (FuzzyResult, Bool, Bool, Bool)] = [
        "sl |Slack": (.scored(score: 6, skipped: 1), true, true, true),
        "s |Safari": (.scored(score: 4, skipped: 1), true, true, true),
    ]

    static func all() -> [ScorerCase] {
        let cases = Fixtures.search["scorer"] as! [[String: Any]]
        return cases.map { c in
            let query = c["query"] as! String, text = c["text"] as! String
            let t = c["threshold"] as! [String: Bool]
            var expected = parse(c["fuzzyLiteralDots"]!)
            var (low, medium, high) = (t["low"]!, t["medium"]!, t["high"]!)
            var floor = parseValue(c["wholeWordFloor"]!)
            if let fix = fixedQuirks["\(query)|\(text)"] {
                (expected, low, medium, high) = fix
                floor = expected.value
            }
            return ScorerCase(query: query, text: text, transliteratedQuery: c["transliteratedQuery"] as! String,
                              expected: expected, low: low, medium: medium, high: high,
                              titlePrefix: c["titlePrefix"] as! String, wholeWord: c["wholeWord"] as! Bool,
                              wholeWordFloor: floor)
        }
    }

    static func parse(_ v: Any) -> FuzzyResult {
        if let s = v as? String { return s == "exact" ? .exact : .unmatched }
        let d = v as! [String: Any]
        return .scored(score: (d["score"] as! NSNumber).intValue, skipped: (d["skipped"] as! NSNumber).intValue)
    }

    static func parseValue(_ v: Any) -> Double {
        if let s = v as? String { return s == "MAX" ? FuzzyScorer.maxScore : FuzzyScorer.minScore }
        return (v as! NSNumber).doubleValue
    }
}

struct FuzzyScorerTests {
    @Test(arguments: ScorerCase.all())
    func goldenScore(_ c: ScorerCase) {
        let q = SearchQuery(c.query)
        let target = Normalizer.target(c.text)
        #expect(String(decoding: q.transliterated, as: UTF16.self) == c.transliteratedQuery)

        let result = FuzzyScorer.score(target, q.transliterated)
        #expect(result == c.expected)

        let len = q.transliterated.count
        #expect(FuzzyScorer.passes(result, queryLength: len, sensitivity: .low) == c.low)
        #expect(FuzzyScorer.passes(result, queryLength: len, sensitivity: .medium) == c.medium)
        #expect(FuzzyScorer.passes(result, queryLength: len, sensitivity: .high) == c.high)

        let prefix: String = switch FuzzyScorer.prefix(target.text, q.transliterated) {
        case .exact: "exact"
        case .prefix: "prefix"
        case .unmatched: "unmatched"
        }
        #expect(prefix == c.titlePrefix)
        #expect(FuzzyScorer.isWholeWord(target, q.transliterated) == c.wholeWord)
        if case .scored = result {
            #expect(FuzzyScorer.wholeWordFloor(target, score: result.value, query: q.transliterated) == c.wholeWordFloor)
        }
    }

    @Test func emptyQueryScoresMinimum() {
        #expect(FuzzyScorer.score(Normalizer.target("Safari"), []) == .scored(score: -9_007_199_254_740_991, skipped: 0))
    }
}

struct NormalizerTests {
    nonisolated static let cases: [(String, String)] = (Fixtures.search["normalization"] as! [[String: Any]]).map {
        ($0["input"] as! String, $0["translit"] as! String)
    }

    @Test(arguments: zip(cases.map(\.0), cases.map(\.1)))
    func transliteration(_ input: String, _ expected: String) {
        #expect(Normalizer.transliterate(input).lowercased() == expected.lowercased())
    }

    @Test func camelBoundaries() {
        let t = FuzzyTarget("abXba")
        #expect(t.boundaries.enumerated().filter(\.element).map(\.offset) == [2])
        #expect(FuzzyTarget("Slack").boundaries.isEmpty)
    }
}

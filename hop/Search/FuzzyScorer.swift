import Foundation

nonisolated enum FuzzyResult: Sendable, Equatable {
    case unmatched
    case exact
    case scored(score: Int, skipped: Int)

    /// Numeric value used for ordering (`of` in Raycast).
    var value: Double {
        switch self {
        case .unmatched: FuzzyScorer.minScore
        case .exact: FuzzyScorer.maxScore
        case .scored(let s, _): Double(s)
        }
    }
}

nonisolated enum Sensitivity: String, Sendable, Codable, CaseIterable {
    case low, medium, high
}

/// Port of Raycast 2.8.2 root-search scorer `af` (see raycast-re spec-search.md §3),
/// with the stale DP row bug fixed: rows are cleared, and an unmatched separator row
/// is rolled back even when it is the last row.
nonisolated enum FuzzyScorer {
    static let minScore = -9_007_199_254_740_991.0
    static let maxScore = 9_007_199_254_740_991.0
    private static let minInt = -9_007_199_254_740_991

    static let first = 4, wordBeginning = 3, regular = 2, limiter = 1
    private static let precheckThreshold = 2

    /// `\t \n space - . / ( ) [ ]`
    @inline(__always) static func isSeparator(_ c: UInt16) -> Bool {
        switch c {
        case 9, 10, 32, 45, 46, 47, 40, 41, 91, 93: true
        default: false
        }
    }

    @inline(__always) private static func isQuerySeparator(_ c: UInt16, literalDots: Bool) -> Bool {
        isSeparator(c) && !(literalDots && c == 46)
    }

    @inline(__always) private static func positionScore(_ t: FuzzyTarget, _ i: Int) -> Int {
        (t.isBoundary(i) || isSeparator(t.text[i - 1])) && !isSeparator(t.text[i]) ? wordBeginning : regular
    }

    static func score(_ target: FuzzyTarget, _ q: [UInt16], literalDots: Bool = true) -> FuzzyResult {
        let r = target.text
        if r == q { return .exact }
        let s = r.count, c = q.count

        var nonSep = 0
        for ch in q where !isQuerySeparator(ch, literalDots: literalDots) { nonSep += 1 }
        if nonSep > s { return .unmatched }

        if nonSep > precheckThreshold {
            var e = 0
            for ch in q {
                if isQuerySeparator(ch, literalDots: literalDots) {
                    if e < s && isSeparator(r[e]) { e += 1 }
                    continue
                }
                var found = false
                while e < s {
                    if r[e] == ch { e += 1; found = true; break }
                    e += 1
                }
                if !found { return .unmatched }
            }
        }

        var prev = [Int](repeating: minInt, count: s)
        var cur = [Int](repeating: minInt, count: s)
        var firstPrev = -1, skipped = 0, matchedRows = 0

        for row in 0..<c {
            for i in 0..<s { cur[i] = minInt }
            let ch = q[row]
            let sepRow = isQuerySeparator(ch, literalDots: literalDots)
            let remaining = nonSep - 1 - matchedRows
            let lo = firstPrev + 1
            let hi = min(s - remaining, s)
            var firstMatch = -1

            if lo < hi {
                for col in lo..<hi {
                    let tc = r[col]
                    let eq = tc == ch
                    let sepToSep = !eq && sepRow && isSeparator(tc)
                    guard eq || sepToSep else { continue }
                    if firstPrev < 0 {
                        cur[col] = sepToSep ? limiter : (col == 0 ? first : positionScore(target, col))
                    } else {
                        let cs = sepToSep ? limiter : positionScore(target, col)
                        var best = minInt
                        for pc in firstPrev..<col {
                            let v = prev[pc]
                            if v <= minInt { continue }
                            best = max(best, v + cs - (pc == col - 1 ? 0 : 1))
                        }
                        cur[col] = best
                    }
                    if firstMatch < 0 { firstMatch = col }
                }
            }

            if firstMatch >= 0 {
                firstPrev = firstMatch
                matchedRows += 1
                swap(&prev, &cur)
            } else if sepRow {
                skipped += 1
            } else {
                return .unmatched
            }
        }

        let best = matchedRows == 0 ? minInt : (prev.max() ?? minInt)
        return .scored(score: best, skipped: skipped)
    }

    /// Sensitivity threshold `rf`. `queryLength` includes separators.
    static func passes(_ result: FuzzyResult, queryLength: Int, sensitivity: Sensitivity) -> Bool {
        switch result {
        case .unmatched: return false
        case .exact: return true
        case .scored(let score, let skipped):
            let s = Double(score), len = Double(queryLength - skipped)
            switch sensitivity {
            case .low: return true
            case .medium: return s >= 1.5 * (len - 2) + 4
            case .high: return s > 2 * len
            }
        }
    }

    /// `J7e`: prefix / exact / unmatched.
    enum PrefixMatch: Sendable, Equatable { case exact, prefix, unmatched }

    static func prefix(_ text: [UInt16], _ q: [UInt16]) -> PrefixMatch {
        if text.count > q.count { return text.starts(with: q) ? .prefix : .unmatched }
        return text.count == q.count && text == q ? .exact : .unmatched
    }

    /// `q7e`: q occurs as a whole word (boundary at both ends).
    static func isWholeWord(_ t: FuzzyTarget, _ q: [UInt16]) -> Bool {
        guard !q.isEmpty, !q.contains(where: { isSeparator($0) || $0 == 0x0B || $0 == 0x0C || $0 == 0x0D || $0 == 0xA0 })
        else { return false }
        let n = t.text, m = q.count
        guard m <= n.count else { return false }
        var i = 0
        while i + m <= n.count {
            if n[i] == q[0] && n[i..<(i + m)].elementsEqual(q) {
                let e = i + m
                let startOK = i == 0 || t.isBoundary(i) || isSeparator(n[i - 1])
                let endOK = e == n.count || t.isBoundary(e) || isSeparator(n[e])
                if startOK && endOK { return true }
            }
            i += 1
        }
        return false
    }

    /// Whole-word floor (`$Yi`): lifts a whole-word match to `4 + 2(len-1) + 0.5`.
    static func wholeWordFloor(_ t: FuzzyTarget, score: Double, query q: [UInt16]) -> Double {
        let floor = 4 + 2 * Double(q.count - 1) + 0.5
        if score == minScore || q.count < 3 || score >= floor || !isWholeWord(t, q) { return score }
        return floor
    }
}

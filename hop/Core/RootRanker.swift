import Foundation

/// Everything the ranker needs about one root-search item, precomputed at index time.
nonisolated struct RankCandidate: Sendable {
    let id: String
    let title: String
    let target: FuzzyTarget
    let alternates: [FuzzyTarget]
    let subtitle: FuzzyTarget?
    /// Keywords plus "title subtitle" / "subtitle title" combos: gate inclusion only.
    let keywords: [FuzzyTarget]
    let typeWeight: Int
    var frecency: Double

    init(id: String, title: String, alternateTitles: [String] = [], subtitle: String? = nil,
         keywords: [String] = [], typeWeight: Int, frecency: Double = 1) {
        self.id = id
        self.title = title
        let t = Normalizer.target(title)
        target = t
        var seen: Set<String> = [title.lowercased()]
        alternates = alternateTitles.compactMap { alt in
            seen.insert(alt.lowercased()).inserted ? Normalizer.alternateTarget(alt) : nil
        }
        let sub = subtitle.flatMap { $0.isEmpty ? nil : Normalizer.target($0) }
        self.subtitle = sub
        var kw = Array(Set(keywords)).sorted().map(Normalizer.target)
        if let sub, sub.text != t.text {
            let titleText = Normalizer.transliterate(title), subText = Normalizer.transliterate(subtitle!)
            kw.append(Normalizer.target("\(titleText) \(subText)"))
            kw.append(Normalizer.target("\(subText) \(titleText)"))
        }
        self.keywords = kw
        self.typeWeight = typeWeight
        self.frecency = frecency
    }
}

/// Type weights from Raycast `lXi` (spec-search.md §5d).
nonisolated enum TypeWeight {
    static let application = 5, command = 4, quicklink = 3, menuBar = 3, preference = 1, file = 1
}

/// Port of Raycast's root-search ranking (`iXi`, `$Yi`, `sXi`, `B4`) without aliases,
/// stored search terms, boosted terms, contacts and pins, which hop does not have.
nonisolated enum RootRanker {
    struct Ranking: Sendable {
        var title: Double
        var titleMatch: FuzzyScorer.PrefixMatch
        var subtitle: FuzzyResult
        var subtitleExact: Bool { subtitle == .exact }
        var isMatching: Bool
    }

    static func ranking(_ c: RankCandidate, query q: SearchQuery, sensitivity: Sensitivity) -> Ranking {
        let r = q.transliterated, n = q.lowercased
        let title = FuzzyScorer.score(c.target, r)
        let alts = c.alternates.map { FuzzyScorer.score($0, n) }

        var titleMatch: FuzzyScorer.PrefixMatch = .unmatched
        if title == .exact {
            titleMatch = .exact
        } else if FuzzyScorer.prefix(c.target.text, r) == .prefix
                    || c.alternates.contains(where: { FuzzyScorer.prefix($0.text, n) == .prefix }) {
            titleMatch = .prefix
        }

        let subtitle: FuzzyResult = if let sub = c.subtitle, sub.text != c.target.text {
            FuzzyScorer.score(sub, r)
        } else {
            .unmatched
        }

        let matching = FuzzyScorer.passes(title, queryLength: r.count, sensitivity: sensitivity)
            || alts.contains { FuzzyScorer.passes($0, queryLength: n.count, sensitivity: sensitivity) }
            || FuzzyScorer.passes(subtitle, queryLength: r.count, sensitivity: sensitivity)
            || c.keywords.contains { FuzzyScorer.passes(FuzzyScorer.score($0, r), queryLength: r.count, sensitivity: sensitivity) }

        // Whole-word floor and alternate titles (`$Yi`).
        var titleValue = title.value
        let wholeWord = n.count >= 3 && !n.contains(where: { $0 == 32 || $0 == 9 || $0 == 10 })
        if titleMatch != .exact {
            if wholeWord { titleValue = FuzzyScorer.wholeWordFloor(c.target, score: titleValue, query: r) }
            for (i, alt) in alts.enumerated() {
                if alt == .exact {
                    titleValue = FuzzyScorer.maxScore
                    titleMatch = .exact
                    break
                }
                var v = alt.value
                if wholeWord { v = FuzzyScorer.wholeWordFloor(c.alternates[i], score: v, query: n) }
                titleValue = max(titleValue, v)
            }
        }
        return Ranking(title: titleValue, titleMatch: titleMatch, subtitle: subtitle, isMatching: matching)
    }

    /// Ranked indices of matching candidates for a non-empty query.
    static func rank(_ candidates: [RankCandidate], query q: SearchQuery, sensitivity: Sensitivity) -> [Int] {
        var ranked: [(index: Int, r: Ranking)] = []
        ranked.reserveCapacity(64)
        for (i, c) in candidates.enumerated() {
            let r = ranking(c, query: q, sensitivity: sensitivity)
            if r.isMatching { ranked.append((i, r)) }
        }
        let anyExactTitle = q.transliterated.count >= 3 && ranked.contains { $0.r.titleMatch == .exact }
        ranked.sort { a, b in
            compare(candidates[a.index], a.r, candidates[b.index], b.r, anyExactTitle: anyExactTitle) < 0
        }
        return ranked.map(\.index)
    }

    /// Ordering for the empty query (`B4`).
    static func rankEmpty(_ candidates: [RankCandidate]) -> [Int] {
        Array(candidates.indices).sorted { base(candidates[$0], candidates[$1]) < 0 }
    }

    /// `sXi` subset. Negative means `a` first.
    static func compare(_ a: RankCandidate, _ ra: Ranking, _ b: RankCandidate, _ rb: Ranking, anyExactTitle: Bool) -> Int {
        let df = b.frecency - a.frecency
        if anyExactTitle {
            let ae = ra.titleMatch == .exact, be = rb.titleMatch == .exact
            if ae && be { return df != 0 ? sign(df) : base(a, b) }
            if ae != be { return ae ? -1 : 1 }
        }
        if ra.subtitleExact || rb.subtitleExact {
            if ra.subtitleExact && rb.subtitleExact {
                if df != 0 { return sign(df) }
                if ra.title != rb.title { return sign(rb.title - ra.title) }
                return base(a, b)
            }
            return ra.subtitleExact ? -1 : 1
        }
        let ma = max(ra.title, ra.subtitle.value), mb = max(rb.title, rb.subtitle.value)
        if ma != mb { return mb > ma ? 1 : -1 }
        if df != 0 { return sign(df) }
        if ra.title != rb.title { return rb.title > ra.title ? 1 : -1 }
        if a.typeWeight != b.typeWeight { return b.typeWeight - a.typeWeight }
        return collate(a.title, b.title)
    }

    /// `B4` subset: frecency, type weight, title.
    static func base(_ a: RankCandidate, _ b: RankCandidate) -> Int {
        if a.frecency != b.frecency { return a.frecency > b.frecency ? -1 : 1 }
        if a.typeWeight != b.typeWeight { return b.typeWeight - a.typeWeight }
        return collate(a.title, b.title)
    }

    private static func sign(_ d: Double) -> Int { d > 0 ? 1 : (d < 0 ? -1 : 0) }

    private static func collate(_ a: String, _ b: String) -> Int {
        switch a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive]) {
        case .orderedAscending: -1
        case .orderedDescending: 1
        case .orderedSame: 0
        }
    }
}

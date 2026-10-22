import Foundation

/// Text prepared for fuzzy matching: lower-cased UTF-16 plus camelCase word boundaries
/// computed on the original-case string.
nonisolated struct FuzzyTarget: Sendable, Equatable {
    let text: [UInt16]
    let boundaries: [Bool]

    init(_ original: String) {
        let lower = Array(original.lowercased().utf16)
        let source = Array(original.utf16)
        text = lower
        guard source.count == lower.count, source.count > 1 else {
            boundaries = []
            return
        }
        var marks = [Bool](repeating: false, count: source.count)
        var any = false
        for i in 1..<source.count {
            let prev = source[i - 1], cur = source[i]
            let prevLowerOrDigit = (prev >= 97 && prev <= 122) || (prev >= 48 && prev <= 57)
            if prevLowerOrDigit && cur >= 65 && cur <= 90 {
                marks[i] = true
                any = true
            }
        }
        boundaries = any ? marks : []
    }

    func isBoundary(_ i: Int) -> Bool { i < boundaries.count && boundaries[i] }
}

/// The three forms of a search term used by ranking.
nonisolated struct SearchQuery: Sendable {
    let raw: String
    /// `trimStart`, NFC, lower-cased; used for alternate titles.
    let lowercased: [UInt16]
    /// `trimStart`, NFC, transliterated to ASCII, lower-cased; used for titles, subtitles, keywords.
    let transliterated: [UInt16]

    var hasTerm: Bool { !raw.isEmpty }

    init(_ term: String) {
        raw = term
        let trimmed = String(term.drop(while: { $0.isWhitespace })).precomposedStringWithCanonicalMapping
        lowercased = Array(trimmed.lowercased().utf16)
        transliterated = Array(Normalizer.transliterate(trimmed).lowercased().utf16)
    }
}

nonisolated enum Normalizer {
    private static let toASCII = StringTransform("Any-Latin; Latin-ASCII")

    /// NFC + ICU `Any-Latin; Latin-ASCII`. ASCII input is returned untouched.
    static func transliterate(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        if nfc.utf8.allSatisfy({ $0 < 0x80 }) { return nfc }
        return nfc.applyingTransform(toASCII, reverse: false) ?? nfc
    }

    /// Title, subtitle or keyword: transliterated, then lower-cased with camel boundaries.
    static func target(_ s: String) -> FuzzyTarget { FuzzyTarget(transliterate(s)) }

    /// Alternate titles are only NFC-normalized, not transliterated (Raycast behaviour).
    static func alternateTarget(_ s: String) -> FuzzyTarget {
        FuzzyTarget(s.precomposedStringWithCanonicalMapping)
    }
}

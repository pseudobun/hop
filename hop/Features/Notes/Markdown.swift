import Foundation

/// What a stretch of Markdown source is, for live styling in the editor.
nonisolated enum MarkdownSpan: Equatable, Sendable {
    case frontmatter
    /// A whole heading line, level 1–6.
    case heading(Int)
    /// Syntax characters (`#`, `**`, `` ` ``, `>`, bullets, brackets), drawn faint.
    case marker
    case bold, italic, strike, highlight, code, codeBlock, quote, rule, tag
    /// Link text; the target is `note:<wiki target>` or a URL.
    case link(String)
    /// The `[ ]` / `[x]` box of a task.
    case task(done: Bool)
    /// Text of a finished task.
    case doneText
}

nonisolated struct StyledRange: Equatable, Sendable {
    let range: NSRange
    let span: MarkdownSpan
}

/// Line-based Markdown highlighter (CommonMark plus Obsidian's `[[links]]`, `==highlights==`
/// and `#tags`). Source stays visible; markers are only dimmed. Ranges are UTF-16.
nonisolated enum MarkdownStyler {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private nonisolated(unsafe) static let heading = re(#"^(#{1,6})[ \t]+"#)
    private nonisolated(unsafe) static let rule = re(#"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private nonisolated(unsafe) static let quote = re(#"^[ \t]*(?:>[ \t]?)+"#)
    private nonisolated(unsafe) static let bullet = re(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+"#)
    private nonisolated(unsafe) static let task = re(#"\G\[([ xX])\](?=[ \t]|$)"#)
    private nonisolated(unsafe) static let inlineCode = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private nonisolated(unsafe) static let wikiLink = re(#"!?\[\[([^\[\]\n]+?)\]\]"#)
    private nonisolated(unsafe) static let mdLink = re(#"!?\[([^\[\]\n]+)\]\(([^()\s]+)\)"#)
    private nonisolated(unsafe) static let url = re(#"https?://[^\s<>()\[\]`]+[^\s<>()\[\]`.,;:!?'"]"#)
    private nonisolated(unsafe) static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private nonisolated(unsafe) static let italicStar = re(#"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)
    private nonisolated(unsafe) static let italicUnderscore = re(#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)
    private nonisolated(unsafe) static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private nonisolated(unsafe) static let highlight = re(#"==(?=\S)(.+?)(?<=\S)=="#)
    private nonisolated(unsafe) static let tag = re(#"(?<![\w#/&])#[\p{L}_][\p{L}\p{N}_/-]*"#)

    static func spans(_ text: String) -> [StyledRange] {
        let ns = text as NSString
        var out: [StyledRange] = []
        var location = 0, lineNumber = 0
        var inFrontmatter = false, fence: String?

        while location < ns.length {
            var end = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let lineRange = NSRange(location: location, length: contentsEnd - location)
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { location = end; lineNumber += 1 }

            if lineNumber == 0 && line == "---" { inFrontmatter = true }
            if inFrontmatter {
                out.append(StyledRange(range: lineRange, span: .frontmatter))
                if lineNumber > 0 && (line == "---" || line == "...") { inFrontmatter = false }
                continue
            }
            if let open = fence {
                out.append(StyledRange(range: lineRange, span: .codeBlock))
                if trimmed.hasPrefix(open) && trimmed.allSatisfy({ String($0) == String(open.first!) }) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix { $0 == trimmed.first })
                out.append(StyledRange(range: lineRange, span: .codeBlock))
                continue
            }
            styleLine(line, at: location, into: &out)
        }
        return out
    }

    private static func styleLine(_ line: String, at offset: Int, into out: inout [StyledRange]) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        func add(_ r: NSRange, _ s: MarkdownSpan) {
            if r.location != NSNotFound && r.length > 0 { out.append(StyledRange(range: NSRange(location: r.location + offset, length: r.length), span: s)) }
        }
        func first(_ regex: NSRegularExpression, from: Int = 0) -> NSTextCheckingResult? {
            regex.firstMatch(in: line, range: NSRange(location: from, length: ns.length - from))
        }

        if let h = first(heading) {
            add(full, .heading(h.range(at: 1).length))
            add(h.range(at: 1), .marker)
        } else if first(rule) != nil {
            add(full, .rule)
            return
        }

        var inline = 0
        if let q = first(quote) {
            add(full, .quote)
            add(q.range, .marker)
            inline = q.range.upperBound
        }
        if let b = bullet.firstMatch(in: line, range: NSRange(location: inline, length: ns.length - inline)), b.range.location == inline {
            add(b.range, .marker)
            inline = b.range.upperBound
            if let t = task.firstMatch(in: line, range: NSRange(location: inline, length: ns.length - inline)) {
                let done = ns.substring(with: t.range(at: 1)) != " "
                add(t.range, .task(done: done))
                if done { add(NSRange(location: t.range.upperBound, length: ns.length - t.range.upperBound), .doneText) }
            }
        }

        // Code spans first: nothing inside them is Markdown.
        var taken: [NSRange] = []
        for m in inlineCode.matches(in: line, range: full) {
            let ticks = m.range(at: 1).length
            add(m.range, .code)
            add(NSRange(location: m.range.location, length: ticks), .marker)
            add(NSRange(location: m.range.upperBound - ticks, length: ticks), .marker)
            taken.append(m.range)
        }
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in wikiLink.matches(in: line, range: full) where free(m.range) {
            let inner = m.range(at: 1)
            let target = ns.substring(with: inner)
            add(NSRange(location: m.range.location, length: inner.location - m.range.location), .marker)
            add(inner, .link("note:" + target))
            add(NSRange(location: inner.upperBound, length: 2), .marker)
            taken.append(m.range)
        }
        for m in mdLink.matches(in: line, range: full) where free(m.range) {
            let text = m.range(at: 1)
            add(NSRange(location: m.range.location, length: text.location - m.range.location), .marker)
            add(text, .link(ns.substring(with: m.range(at: 2))))
            add(NSRange(location: text.upperBound, length: m.range.upperBound - text.upperBound), .marker)
            taken.append(m.range)
        }
        for m in url.matches(in: line, range: full) where free(m.range) {
            add(m.range, .link(ns.substring(with: m.range)))
            taken.append(m.range)
        }
        let pairs: [(NSRegularExpression, MarkdownSpan, Int)] = [
            (bold, .bold, 2), (italicStar, .italic, 1), (italicUnderscore, .italic, 1), (strike, .strike, 2), (highlight, .highlight, 2),
        ]
        for (regex, span, width) in pairs {
            for m in regex.matches(in: line, range: full) where free(m.range) {
                add(m.range, span)
                add(NSRange(location: m.range.location, length: width), .marker)
                add(NSRange(location: m.range.upperBound - width, length: width), .marker)
            }
        }
        for m in tag.matches(in: line, range: full) where free(m.range) { add(m.range, .tag) }
    }
}

/// Small editing commands: list continuation, task and emphasis toggles.
nonisolated enum MarkdownEditing {
    enum Continuation: Equatable {
        /// Insert a newline followed by this prefix.
        case insert(String)
        /// The item was empty: remove its bullet instead of starting another.
        case endList(bulletLength: Int)
    }

    private nonisolated(unsafe) static let item = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]?)*)([-*+]|(\d+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)

    /// What ↵ at the end of `line` should do; nil when the line is not a list item.
    static func continueList(_ line: String) -> Continuation? {
        let ns = line as NSString
        guard let m = item.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        if m.range.upperBound == ns.length || ns.substring(from: m.range.upperBound).allSatisfy(\.isWhitespace) {
            return .endList(bulletLength: ns.length)
        }
        let indent = ns.substring(with: m.range(at: 1))
        var bullet = ns.substring(with: m.range(at: 2))
        if m.range(at: 3).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 3))) {
            bullet = "\(n + 1)" + ns.substring(with: m.range(at: 4))
        }
        let space = ns.substring(with: m.range(at: 5))
        let box = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
        return .insert(indent + bullet + space + box)
    }

    /// `- [ ] x` ⇄ `- [x] x`; a plain item or line becomes an open task.
    static func toggleTask(_ line: String) -> String {
        if let r = line.firstMatch(of: /^(\s*[-*+]\s+)\[ \]/) { return line.replacingCharacters(in: r.range, with: r.output.1 + "[x]") }
        if let r = line.firstMatch(of: /^(\s*[-*+]\s+)\[[xX]\]/) { return line.replacingCharacters(in: r.range, with: r.output.1 + "[ ]") }
        if let r = line.firstMatch(of: /^(\s*[-*+]\s+)/) { return line.replacingCharacters(in: r.range, with: r.output.1 + "[ ] ") }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return indent + "- [ ] " + line.dropFirst(indent.count)
    }

    /// Wraps `selected` in `marker`, or unwraps it when it already is.
    static func toggleWrap(_ selected: String, marker: String) -> String {
        if selected.count >= marker.count * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            return String(selected.dropFirst(marker.count).dropLast(marker.count))
        }
        return marker + selected + marker
    }
}

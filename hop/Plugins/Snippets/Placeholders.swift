import Foundation

/// Raycast's dynamic placeholders for snippets (raycast-re spec-placeholders.md):
/// `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{day}`, `{uuid}`, `{cursor}`,
/// `{argument}`, `{snippet}`, `{calculator}` with options and `| modifiers`.
nonisolated enum Placeholder: Equatable, Sendable {
    enum DateUnit: String, Sendable { case date, time, datetime, day }
    struct Offset: Equatable, Sendable {
        let unit: Character // m h d M y
        let amount: Int
    }

    case clipboard(offset: Int)
    case date(DateUnit, format: String?, locale: String?, offsets: [Offset])
    case uuid
    case cursor
    case argument(position: Int, name: String?, defaultValue: String?, options: [String]?)
    case snippet(name: String)
    case calculator(expression: String)
}

nonisolated struct ParsedPlaceholder: Equatable, Sendable {
    /// UTF-16 offsets into the text, like Raycast's JS ranges.
    let start: Int
    let end: Int
    let value: Placeholder?
    let modifiers: [String]
    let error: String?
}

nonisolated enum Placeholders {
    static let modifierNames: Set<String> = ["uppercase", "lowercase", "trim", "percent-encode", "json-stringify", "raw"]
    private static let dateKeywords: Set<String> = ["date", "time", "datetime", "day"]

    // MARK: Tokenizer

    private struct Raw {
        var start = 0, end = 0
        var keyword = ""
        var options: [(String, String)] = []
        var modifiers: [String] = []
        var deprecatedFormat: String?
        var deprecatedOffsets: String?
    }

    private enum Attempt {
        case placeholder(Raw)
        /// Not a placeholder; continue scanning at this offset.
        case resume(Int)
    }

    private static func isLetter(_ u: UInt16) -> Bool {
        guard let s = Unicode.Scalar(u) else { return false }
        return s.properties.isAlphabetic
    }

    private static func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 11 || u == 12 || u == 0xA0 }
    private static func isNewline(_ u: UInt16) -> Bool { u == 10 || u == 13 }

    /// Closing quote characters accepted for an opening quote.
    private static func closers(_ open: UInt16) -> Set<UInt16>? {
        switch open {
        case 0x22: [0x22, 0x201D] // " → " ”
        case 0x27: [0x27, 0x2019] // ' → ' ’
        case 0x60: [0x60] // `
        case 0x201C, 0x201D: [0x201D, 0x22] // “ ” → ” "
        case 0x2018, 0x2019: [0x2019, 0x27] // ‘ ’ → ’ '
        default: nil
        }
    }

    /// Every well-formed placeholder in `text`, with semantic errors where Raycast reports them.
    static func parse(_ text: String, snippets: [Snippet] = [], selfName: String? = nil) -> [ParsedPlaceholder] {
        let u = Array(text.utf16)
        var raws: [Raw] = []
        var i = 0
        while i < u.count {
            guard u[i] == 0x7B else { i += 1; continue } // {
            switch attempt(u, at: i) {
            case .placeholder(let r):
                raws.append(r)
                i = r.end
            case .resume(let next):
                i = max(next, i + 1)
            }
        }
        return interpret(raws, snippets: snippets, selfName: selfName)
    }

    private static func attempt(_ u: [UInt16], at start: Int) -> Attempt {
        var j = start + 1
        var raw = Raw()
        raw.start = start
        var innerBrace: Int?
        func fail(at k: Int) -> Attempt {
            if let innerBrace { return .resume(innerBrace) }
            if k < u.count && u[k] == 0x7B { return .resume(k) } // a { restarts here
            return .resume(start + 1)
        }
        func skipSpace() -> Int {
            let from = j
            while j < u.count && isSpace(u[j]) { j += 1 }
            return j - from
        }
        _ = skipSpace()
        // keyword
        guard j < u.count, isLetter(u[j]) else { return fail(at: j) }
        let kwStart = j
        while j < u.count && (isLetter(u[j]) || u[j] == 0x2E || u[j] == 0x2D) { j += 1 }
        raw.keyword = String(utf16CodeUnits: Array(u[kwStart..<j]), count: j - kwStart)
        let keywordLower = raw.keyword.lowercased()

        // options or deprecated date
        while true {
            let spaced = skipSpace() > 0
            guard j < u.count else { return fail(at: j) }
            let c = u[j]
            if isNewline(c) { return fail(at: j) }
            if c == 0x7D { // }
                raw.end = j + 1
                return .placeholder(raw)
            }
            if c == 0x7C { break } // |
            if spaced && dateKeywords.contains(keywordLower) && raw.options.isEmpty && (c == 0x22 || c == 0x2B || c == 0x2D) {
                // {date "dd.MM." +3d}
                if c == 0x22 {
                    j += 1
                    let f = j
                    while j < u.count && u[j] != 0x22 && !isNewline(u[j]) { j += 1 }
                    guard j < u.count, u[j] == 0x22 else { return fail(at: j) }
                    raw.deprecatedFormat = String(utf16CodeUnits: Array(u[f..<j]), count: j - f)
                    j += 1
                }
                let o = j
                while j < u.count && u[j] != 0x7D && !isNewline(u[j]) && u[j] != 0x7B { j += 1 }
                guard j < u.count, u[j] == 0x7D else { return fail(at: j) }
                let offsets = String(utf16CodeUnits: Array(u[o..<j]), count: j - o).trimmingCharacters(in: .whitespaces)
                if !offsets.isEmpty { raw.deprecatedOffsets = offsets }
                raw.end = j + 1
                return .placeholder(raw)
            }
            guard spaced, isLetter(c) else { return fail(at: j) }
            // option name=value
            let n = j
            while j < u.count && isLetter(u[j]) { j += 1 }
            let name = String(utf16CodeUnits: Array(u[n..<j]), count: j - n)
            _ = skipSpace()
            guard j < u.count, u[j] == 0x3D else { return fail(at: j) } // =
            j += 1
            _ = skipSpace()
            guard j < u.count else { return fail(at: j) }
            if let close = closers(u[j]) {
                j += 1
                var value: [UInt16] = []
                var closed = false
                while j < u.count {
                    let ch = u[j]
                    if isNewline(ch) { return fail(at: j) }
                    if close.contains(ch) {
                        var slashes = 0
                        while slashes < value.count && value[value.count - 1 - slashes] == 0x5C { slashes += 1 }
                        if slashes % 2 == 1 {
                            value.removeLast() // the escaping backslash
                            value.append(ch)
                            j += 1
                            continue
                        }
                        closed = true
                        j += 1
                        break
                    }
                    if ch == 0x7B && innerBrace == nil { innerBrace = j }
                    value.append(ch)
                    j += 1
                }
                guard closed else { return fail(at: j) }
                raw.options.append((name, String(utf16CodeUnits: value, count: value.count)))
            } else {
                let v = j
                while j < u.count && !isSpace(u[j]) && u[j] != 0x7D && u[j] != 0x3D && u[j] != 0x7B && u[j] != 0x7C && !isNewline(u[j]) {
                    j += 1
                }
                if j < u.count && (u[j] == 0x3D || u[j] == 0x7B) { return fail(at: j) }
                raw.options.append((name, String(utf16CodeUnits: Array(u[v..<j]), count: j - v)))
            }
        }

        // modifiers: "|" m ( "|" m )* "}"
        while true {
            guard j < u.count, u[j] == 0x7C else { return fail(at: j) }
            j += 1
            _ = skipSpace()
            guard j < u.count, isLetter(u[j]) else { return fail(at: j) }
            let m = j
            while j < u.count && (isLetter(u[j]) || u[j] == 0x2D || u[j] == 0x2E) { j += 1 }
            raw.modifiers.append(String(utf16CodeUnits: Array(u[m..<j]), count: j - m))
            _ = skipSpace()
            guard j < u.count else { return fail(at: j) }
            if u[j] == 0x7D {
                raw.end = j + 1
                return .placeholder(raw)
            }
            if u[j] != 0x7C { return fail(at: j) }
        }
    }

    // MARK: Semantics

    private static func interpret(_ raws: [Raw], snippets: [Snippet], selfName: String?) -> [ParsedPlaceholder] {
        var out: [ParsedPlaceholder] = []
        var argumentPositions: [String: Int] = [:]
        var nextArgument = 0
        var sawCursor = false

        for r in raws {
            func done(_ v: Placeholder) { out.append(ParsedPlaceholder(start: r.start, end: r.end, value: v, modifiers: r.modifiers, error: nil)) }
            func error(_ e: String) { out.append(ParsedPlaceholder(start: r.start, end: r.end, value: nil, modifiers: r.modifiers, error: e)) }
            let keyword = r.keyword.lowercased()
            if let bad = r.modifiers.first(where: { !modifierNames.contains($0.lowercased()) }) {
                error("Unknown \"\(bad)\" modifier")
                continue
            }
            var options: [String: String] = [:]
            for (k, v) in r.options { options[k.lowercased()] = v }
            func unknownOption(allowed: Set<String>) -> String? {
                r.options.first { !allowed.contains($0.0.lowercased()) }.map { "Unknown \"\($0.0)\" option" }
            }

            switch keyword {
            case "cursor":
                if let e = unknownOption(allowed: []) { error(e); continue }
                if !r.modifiers.isEmpty { error("The Cursor placeholder doesn't support any modifiers"); continue }
                if sawCursor { error("Only one Cursor placeholder is allowed"); continue }
                sawCursor = true
                done(.cursor)
            case "clipboard":
                if let e = unknownOption(allowed: ["offset"]) { error(e); continue }
                guard let offset = options["offset"].map({ Int($0.trimmingCharacters(in: .whitespaces)) }) ?? 0 else {
                    error("Could not parse the offset option")
                    continue
                }
                done(.clipboard(offset: offset))
            case "uuid":
                if let e = unknownOption(allowed: []) { error(e); continue }
                done(.uuid)
            case "selection":
                error("The Selected Text placeholder isn't available in this context")
            case "date", "time", "datetime", "day":
                let unit = Placeholder.DateUnit(rawValue: keyword)!
                let allowed: Set<String> = unit == .date ? ["format", "locale", "offset"] : ["locale", "offset"]
                if let e = unknownOption(allowed: allowed) { error(e); continue }
                let format = options["format"] ?? (unit == .date ? r.deprecatedFormat : nil)
                if format != nil && options["locale"] != nil {
                    error("The \"format\" and \"locale\" options cannot be used together")
                    continue
                }
                guard let offsets = parseOffsets(options["offset"] ?? r.deprecatedOffsets ?? "") else {
                    error("Could not parse the offset option")
                    continue
                }
                done(.date(unit, format: format, locale: options["locale"], offsets: offsets))
            case "argument":
                if let e = unknownOption(allowed: ["name", "default", "options"]) { error(e); continue }
                let name = options["name"].flatMap { $0.isEmpty ? nil : $0 }
                let position: Int
                if let name, let p = argumentPositions[name] {
                    position = p
                } else {
                    guard nextArgument < 3 else { error("Only 3 different Arguments are allowed"); continue }
                    position = nextArgument
                    nextArgument += 1
                    if let name { argumentPositions[name] = position }
                }
                done(.argument(position: position, name: name, defaultValue: options["default"],
                               options: options["options"].flatMap(parseOptionList)))
            case "snippet":
                if let e = unknownOption(allowed: ["name"]) { error(e); continue }
                guard let name = options["name"], !name.isEmpty else { error("Missing required option \"name\""); continue }
                let matches = snippets.filter { $0.name == name && $0.name != selfName }
                guard matches.count == 1, let target = matches.first else { error("No Snippet named \"\(name)\" found"); continue }
                let nested = parse(target.text).compactMap(\.value)
                if nested.contains(where: { if case .snippet = $0 { true } else if case .argument = $0 { true } else { false } }) {
                    error("Only snippets without {snippet}, {argument} or {ai} dynamic placeholders can be referenced")
                    continue
                }
                done(.snippet(name: name))
            case "calculator":
                if let e = unknownOption(allowed: ["expression"]) { error(e); continue }
                guard let expr = options["expression"], !expr.trimmingCharacters(in: .whitespaces).isEmpty else {
                    error("Missing required option \"expression\"")
                    continue
                }
                done(.calculator(expression: expr))
            case "browser-tab", "browser-tab.url", "browser-tab.title", "browser-tab.content":
                error("The Focused Browser Tab placeholder isn't available in this context")
            default:
                error("Unknown \"\(r.keyword)\" placeholder")
            }
        }
        return out
    }

    /// `+1d -2h`: a sign is required; units m h/H d/D M y/Y.
    static func parseOffsets(_ s: String) -> [Placeholder.Offset]? {
        var out: [Placeholder.Offset] = []
        for token in s.split(whereSeparator: \.isWhitespace) {
            guard let sign = token.first, sign == "+" || sign == "-", let unitChar = token.last else { return nil }
            let unit: Character = switch unitChar {
            case "m": "m"
            case "h", "H": "h"
            case "d", "D": "d"
            case "M": "M"
            case "y", "Y": "y"
            default: "?"
            }
            guard unit != "?", let n = Int(token.dropFirst().dropLast()) else { return nil }
            out.append(.init(unit: unit, amount: sign == "-" ? -n : n))
        }
        return out
    }

    /// `options="a, b\, c"` → values (Raycast's parser, including its escaped-comma quirk).
    static func parseOptionList(_ s: String) -> [String]? {
        if s.isEmpty { return nil }
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let chars = Array(s)
        var items: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count else { return nil } // trailing lone backslash
                current.append(c)
                current.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "," {
                items.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { item in
            var item = item
            if item.count >= 3, Array(item)[1] == "\\", Array(item)[2] == "," { item.removeFirst() } // Raycast quirk
            var out = ""
            var k = item.startIndex
            while k < item.endIndex {
                let c = item[k]
                let next = item.index(after: k)
                if c == "\\", next < item.endIndex, "\",\\:".contains(item[next]) {
                    out.append(item[next])
                    k = item.index(after: next)
                } else {
                    out.append(c)
                    k = next
                }
            }
            return out
        }
    }

    // MARK: Expansion

    struct Context {
        var clipboard: (Int) -> String = { _ in "" }
        var arguments: [String] = []
        var snippets: [Snippet] = []
        var now = Date()
        var locale = Locale.current
        var calculate: (String) -> String? = { _ in nil }
    }

    struct Expansion: Equatable {
        let text: String
        /// Characters after the `{cursor}` position, for moving the caret back.
        let charactersAfterCursor: Int?
    }

    enum ExpansionError: Error, Equatable { case placeholder(String) }

    /// Replaces placeholders right to left; the first error stops the expansion.
    static func expand(_ text: String, name: String? = nil, context: Context, depth: Int = 0) throws -> Expansion {
        let parsed = parse(text, snippets: context.snippets, selfName: name)
        let ns = NSMutableString(string: text)
        var cursorAt: Int?
        for p in parsed.sorted(by: { $0.start > $1.start }) {
            if let e = p.error { throw ExpansionError.placeholder(e) }
            guard let v = p.value else { continue }
            var value: String
            switch v {
            case .cursor:
                value = ""
                cursorAt = p.start
            case .clipboard(let offset):
                value = context.clipboard(offset)
            case .uuid:
                value = UUID().uuidString.lowercased()
            case .date(let unit, let format, let locale, let offsets):
                value = formatDate(unit, format: format, locale: locale, offsets: offsets, now: context.now, systemLocale: context.locale)
            case .argument(let position, _, let defaultValue, _):
                value = position < context.arguments.count && !context.arguments[position].isEmpty
                    ? context.arguments[position] : (defaultValue ?? "")
            case .snippet(let n):
                guard depth < 4, let target = context.snippets.first(where: { $0.name == n }) else { value = ""; break }
                value = try expand(target.text, name: n, context: context, depth: depth + 1).text
            case .calculator(let expression):
                value = context.calculate(expression) ?? "Invalid expression"
            }
            value = applyModifiers(value, p.modifiers)
            ns.replaceCharacters(in: NSRange(location: p.start, length: p.end - p.start), with: value)
            if let c = cursorAt, c > p.start, v != .cursor {
                cursorAt = c + (value as NSString).length - (p.end - p.start)
            }
        }
        let out = ns as String
        let after = cursorAt.map { (ns.substring(from: $0) as String).count }
        return Expansion(text: out, charactersAfterCursor: after)
    }

    static func applyModifiers(_ value: String, _ modifiers: [String]) -> String {
        modifiers.reduce(value) { v, m in
            switch m.lowercased() {
            case "uppercase": v.uppercased()
            case "lowercase": v.lowercased()
            case "trim": v.trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode": v.addingPercentEncoding(withAllowedCharacters: .urlUnreservedJS) ?? v
            case "json-stringify":
                (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? v
            default: v
            }
        }
    }

    static func formatDate(_ unit: Placeholder.DateUnit, format: String?, locale: String?, offsets: [Placeholder.Offset],
                           now: Date, systemLocale: Locale = .current) -> String {
        var cal = Calendar.current
        cal.locale = systemLocale
        var date = now
        for o in offsets {
            let component: Calendar.Component = switch o.unit {
            case "m": .minute
            case "h": .hour
            case "d": .day
            case "M": .month
            default: .year
            }
            date = cal.date(byAdding: component, value: o.amount, to: date) ?? date
        }
        let f = DateFormatter()
        f.locale = locale.map { Locale(identifier: $0) } ?? systemLocale
        if let format {
            f.dateFormat = dateFnsToICU(format)
            return f.string(from: date)
        }
        let template = switch unit {
        case .date: "yMMMd"
        case .datetime: "yMMMdjmm"
        case .time: "jmm"
        case .day: "EEEE"
        }
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// date-fns → ICU patterns: they share Unicode tokens; Raycast maps `Y` to `y` and
    /// `Z` runs to `xx` / `xxx` outside quotes first.
    static func dateFnsToICU(_ format: String) -> String {
        var out = ""
        var quoted = false
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                quoted.toggle()
                out.append(c)
                i += 1
                continue
            }
            if !quoted && c == "Y" { out.append("y"); i += 1; continue }
            if !quoted && c == "Z" {
                var n = 0
                while i < chars.count && chars[i] == "Z" { n += 1; i += 1 }
                out += n == 5 ? "xxx" : "xx"
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

nonisolated private extension CharacterSet {
    /// What JavaScript's encodeURIComponent leaves alone.
    static let urlUnreservedJS = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}

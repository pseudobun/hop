import Foundation

/// Text edits to the JSON5 config that keep its comments and layout: a value is replaced
/// where it stands, a missing key is added at the top of its object.
nonisolated enum ConfigEdit {
    /// Sets the value at `path` (e.g. ["general", "hotkey"]) to `literal`, JSON5 source such as
    /// `"cmd+space"`, `true` or `["a", "b"]`. Missing objects on the way are created.
    /// nil when the file has no top-level object to put it in.
    static func setting(_ path: [String], to literal: String, in text: String) -> String? {
        guard !path.isEmpty else { return nil }
        let chars = Array(text.utf16)
        var parser = Parser(chars: chars)
        guard let root = parser.document() else { return nil }
        var object = root
        for (depth, key) in path.enumerated() {
            guard let member = object.members.last(where: { $0.key == key }) else {
                let member = nested(Array(path[depth...]), literal)
                return insert(member, into: object, chars: chars)
            }
            if depth == path.count - 1 {
                return replace(member.value.range, with: literal, in: chars)
            }
            guard let child = member.value.object else {
                // A scalar where an object belongs: replace it with the rest of the path.
                return replace(member.value.range, with: "{ " + nested(Array(path[(depth + 1)...]), literal) + " }", in: chars)
            }
            object = child
        }
        return nil
    }

    /// Sets `general.theme`.
    static func settingTheme(in text: String, to value: String) -> String? {
        setting(["general", "theme"], to: literal(value), in: text)
    }

    // MARK: Literals

    static func literal(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    static func literal(_ value: Bool) -> String { value ? "true" : "false" }
    static func literal(_ value: Int) -> String { String(value) }
    static func literal(_ values: [String]) -> String { "[" + values.map { literal($0) }.joined(separator: ", ") + "]" }

    // MARK: Edits

    /// `a: { b: { c: literal } }` for ["a", "b", "c"].
    private static func nested(_ path: [String], _ literal: String) -> String {
        var out = literal
        for (i, key) in path.enumerated().reversed() {
            let name = memberName(key)
            out = i == path.count - 1 ? "\(name): \(out)" : "\(name): { \(out) }"
        }
        return out
    }

    /// A key as JSON5 writes it: bare when it is an identifier, quoted otherwise
    /// ("dev.you.plugin").
    static func memberName(_ key: String) -> String {
        key.wholeMatch(of: /[A-Za-z_$][A-Za-z0-9_$]*/) != nil ? key : literal(key)
    }

    private static func replace(_ range: Range<Int>, with literal: String, in chars: [UInt16]) -> String {
        String(decoding: chars[..<range.lowerBound], as: UTF16.self)
            + literal
            + String(decoding: chars[range.upperBound...], as: UTF16.self)
    }

    private static let newline = u("\n"), space = u(" "), tab = u("\t")

    /// Adds `member` as the object's first member: on its own line when the opening brace ends
    /// its line, otherwise right after the brace.
    private static func insert(_ member: String, into object: Object, chars: [UInt16]) -> String {
        let open = object.open
        var i = open + 1
        while i < chars.count, chars[i] == space || chars[i] == tab || chars[i] == u("\r") { i += 1 }
        let braceEndsLine = i < chars.count && chars[i] == newline
        guard braceEndsLine else {
            return replace(open + 1..<open + 1, with: " \(member),", in: chars)
        }
        let at = i + 1
        let indent: String
        if let first = object.members.first, let own = lineIndent(before: first.keyStart, in: chars) {
            indent = own
        } else {
            indent = (lineIndent(before: open, in: chars, requireBlank: false) ?? "") + "  "
        }
        return replace(at..<at, with: "\(indent)\(member),\n", in: chars)
    }

    /// The whitespace from the start of the line up to `index`; nil when something else
    /// precedes it on that line (unless `requireBlank` is off: then only the leading blanks).
    private static func lineIndent(before index: Int, in chars: [UInt16], requireBlank: Bool = true) -> String? {
        var start = index
        while start > 0, chars[start - 1] != newline { start -= 1 }
        var end = start
        while end < index, chars[end] == space || chars[end] == tab { end += 1 }
        if requireBlank && end != index { return nil }
        return String(decoding: chars[start..<end], as: UTF16.self)
    }

    // MARK: Parser

    fileprivate static func u(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }

    nonisolated struct Object {
        var open: Int
        var members: [Member] = []
    }

    nonisolated struct Member {
        var key: String
        var keyStart: Int
        var value: Value
    }

    nonisolated struct Value {
        var range: Range<Int>
        var object: Object?
    }

    /// Just enough JSON5 to find where keys and values are; nil on anything it can't read.
    nonisolated private struct Parser {
        private func u(_ c: Unicode.Scalar) -> UInt16 { ConfigEdit.u(c) }
        let chars: [UInt16]
        var i = 0

        init(chars: [UInt16]) { self.chars = chars }

        private func at(_ c: Character) -> Bool { i < chars.count && chars[i] == c.utf16.first! }

        mutating func document() -> Object? {
            skip()
            guard at("{"), let v = value(), let object = v.object else { return nil }
            return object
        }

        mutating func skip() {
            while i < chars.count {
                let c = chars[i]
                if c == space || c == tab || c == newline || c == 13 || c == 0xFEFF || c == 0xA0 || c == 0x2028 || c == 0x2029 {
                    i += 1
                } else if at("/"), i + 1 < chars.count, chars[i + 1] == u("/") {
                    while i < chars.count, chars[i] != newline { i += 1 }
                } else if at("/"), i + 1 < chars.count, chars[i + 1] == u("*") {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == u("*") && chars[i + 1] == u("/")) { i += 1 }
                    i = min(i + 2, chars.count)
                } else {
                    return
                }
            }
        }

        mutating func value() -> Value? {
            let start = i
            if at("{") {
                var object = Object(open: i)
                i += 1
                while true {
                    skip()
                    if at("}") { i += 1; break }
                    let keyStart = i
                    guard let key = key() else { return nil }
                    skip()
                    guard at(":") else { return nil }
                    i += 1
                    skip()
                    guard let v = value() else { return nil }
                    object.members.append(Member(key: key, keyStart: keyStart, value: v))
                    skip()
                    if at(",") { i += 1 } else if !at("}") { return nil }
                }
                return Value(range: start..<i, object: object)
            }
            if at("[") {
                i += 1
                while true {
                    skip()
                    if at("]") { i += 1; break }
                    guard value() != nil else { return nil }
                    skip()
                    if at(",") { i += 1 } else if !at("]") { return nil }
                }
                return Value(range: start..<i, object: nil)
            }
            if at("\"") || at("'") {
                guard string() != nil else { return nil }
                return Value(range: start..<i, object: nil)
            }
            while i < chars.count, !at(","), !at("}"), !at("]"), !at("/"), chars[i] != newline, chars[i] != space, chars[i] != tab { i += 1 }
            return i > start ? Value(range: start..<i, object: nil) : nil
        }

        mutating func key() -> String? {
            if at("\"") || at("'") { return string() }
            let start = i
            while i < chars.count, let s = Unicode.Scalar(chars[i]),
                  CharacterSet.alphanumerics.contains(s) || s == "_" || s == "$" { i += 1 }
            return i > start ? String(decoding: chars[start..<i], as: UTF16.self) : nil
        }

        /// A quoted string's contents (escapes kept as written, enough to compare keys).
        mutating func string() -> String? {
            let quote = chars[i]
            i += 1
            let start = i
            while i < chars.count, chars[i] != quote {
                if chars[i] == u("\\") { i += 1 }
                i += 1
            }
            guard i < chars.count else { return nil }
            let s = String(decoding: chars[start..<i], as: UTF16.self)
            i += 1
            return s
        }
    }
}

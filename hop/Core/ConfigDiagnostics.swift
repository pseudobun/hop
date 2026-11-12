import Foundation

/// Something wrong with the config, in plain words, with where it is when known.
nonisolated struct ConfigIssue: Equatable, Sendable {
    var message: String
    var line: Int?
    var column: Int?
}

/// An enum the config takes as a string; its raw values are what the user may write.
nonisolated protocol ConfigChoice {
    static var choices: [String] { get }
}

nonisolated extension ConfigChoice where Self: CaseIterable & RawRepresentable, RawValue == String {
    static var choices: [String] { allCases.map(\.rawValue) }
}

nonisolated extension Sensitivity: ConfigChoice {}
nonisolated extension ShakeDetector.Sensitivity: ConfigChoice {}
nonisolated extension HopConfig.KeePass.PasswordSource: ConfigChoice {}

/// The keys the config understands, read off the default `HopConfig` (property names are
/// the JSON keys), so a new setting is known without listing it twice.
nonisolated indirect enum ConfigSchema: Equatable, Sendable {
    case section([String: ConfigSchema])
    case list(ConfigSchema)
    case choice([String])
    case value
    /// A dictionary such as `hotkeys`: any key goes.
    case anyKeys

    static let hop = describing(HopConfig(), path: "", samples: [
        // Empty by default, so there is no element to look at.
        "bookmarks": HopConfig.Bookmark(),
        "keepass.databases": HopConfig.KeePass.Database(),
    ])

    private static func describing(_ value: Any, path: String, samples: [String: Any]) -> ConfigSchema {
        if let choice = value as? any ConfigChoice { return .choice(type(of: choice).choices) }
        if value is String || value is HopConfig.General.ThemeName || value is Bool || value is Int || value is Double { return .value }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .struct:
            var fields: [String: ConfigSchema] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                fields[label] = describing(child.value, path: path.isEmpty ? label : "\(path).\(label)", samples: samples)
            }
            return .section(fields)
        case .collection:
            guard let element = mirror.children.first?.value ?? samples[path] else { return .list(.value) }
            return .list(describing(element, path: "\(path).0", samples: samples))
        case .dictionary: return .anyKeys
        default: return .value
        }
    }

    /// The node at a key path; array indices step into the element.
    func node(at path: [String]) -> ConfigSchema? {
        var node = self
        for key in path {
            switch node {
            case .section(let fields):
                guard let next = fields[key] else { return nil }
                node = next
            case .list(let element): node = element
            default: return nil
            }
        }
        return node
    }
}

/// A light JSON5 scanner: where each key is, and what a broken file leaves open. It
/// only tracks structure (strings and comments are skipped), so it works on files the
/// decoder rejects.
nonisolated struct ConfigScan {
    struct Position: Equatable {
        var line: Int
        var column: Int
    }

    enum Token: Equatable {
        case key
        case value
        case punctuation(Character)
    }

    /// Every key in file order; array items are their index, e.g. ["bookmarks", "0", "name"].
    var keys: [(path: [String], at: Position)] = []
    /// What is still open at the end: an unterminated string ("\"") or the innermost bracket.
    var unclosed: (what: String, at: Position)?
    /// The last token before the stop offset, and where it ends.
    var last: (token: Token, at: Position)?

    /// Scans UTF-8 bytes up to `stop` (the decoder's error index), or the whole text.
    init(_ text: String, stop: Int = .max) {
        let b = Array(text.utf8)
        var i = 0, line = 1, lineStart = 0
        func pos(_ at: Int) -> Position { Position(line: line, column: at - lineStart + 1) }

        enum Frame { case object(key: String?, open: Position), array(index: Int, open: Position) }
        var stack: [Frame] = []
        var expectKey = false
        let delimiters = Set(" \t\r\n,:{}[]\"'/".utf8)

        func component(_ frame: Frame) -> String {
            switch frame {
            case .object(let key, _): key ?? ""
            case .array(let index, _): String(index)
            }
        }
        /// A string or bare word: a key when an object is waiting for one.
        func word(_ text: String, at start: Position, end: Position) {
            if expectKey, case .object(_, let open) = stack.last {
                keys.append((stack.dropLast().map(component) + [text], start))
                stack[stack.count - 1] = .object(key: text, open: open)
                expectKey = false
                last = (.key, end)
            } else {
                last = (.value, end)
            }
        }

        while i < b.count, i < stop {
            let c = b[i]
            switch c {
            case UInt8(ascii: "\n"):
                i += 1
                line += 1
                lineStart = i
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                i += 1
            case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "/"):
                while i < b.count, b[i] != UInt8(ascii: "\n") { i += 1 }
            case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "*"):
                i += 2
                while i < b.count, !(b[i] == UInt8(ascii: "*") && i + 1 < b.count && b[i + 1] == UInt8(ascii: "/")) {
                    if b[i] == UInt8(ascii: "\n") { line += 1; lineStart = i + 1 }
                    i += 1
                }
                i += 2
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                last = (.punctuation(Character(UnicodeScalar(c))), pos(i))
                stack.append(c == UInt8(ascii: "{") ? .object(key: nil, open: pos(i)) : .array(index: 0, open: pos(i)))
                expectKey = c == UInt8(ascii: "{")
                i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                last = (.punctuation(Character(UnicodeScalar(c))), pos(i))
                _ = stack.popLast()
                expectKey = false
                i += 1
            case UInt8(ascii: ","):
                last = (.punctuation(","), pos(i))
                switch stack.last {
                case .array(let index, let open): stack[stack.count - 1] = .array(index: index + 1, open: open)
                case .object: expectKey = true
                case nil: break
                }
                i += 1
            case UInt8(ascii: ":"):
                last = (.punctuation(":"), pos(i))
                expectKey = false
                i += 1
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                let start = pos(i), from = i + 1
                i += 1
                while i < b.count, b[i] != c {
                    if b[i] == UInt8(ascii: "\\") { i += 1 }
                    if i < b.count, b[i] == UInt8(ascii: "\n") { line += 1; lineStart = i + 1 }
                    i += 1
                }
                guard i < b.count else {
                    if stop == .max { unclosed = ("\"", start) }
                    return
                }
                word(String(decoding: b[from..<i], as: UTF8.self), at: start, end: pos(i))
                i += 1
            default:
                let start = i
                while i < b.count, i < stop, !delimiters.contains(b[i]) { i += 1 }
                if i == start { i += 1 } // a lone "/"
                word(String(decoding: b[start..<i], as: UTF8.self), at: pos(start), end: pos(i - 1))
            }
        }
        if stop == .max, let frame = stack.last {
            switch frame {
            case .object(_, let open): unclosed = ("{", open)
            case .array(_, let open): unclosed = ("[", open)
            }
        }
    }

    /// Where a key is, or its closest enclosing key that is in the file.
    func position(of path: [String]) -> Position? {
        var path = path
        while !path.isEmpty {
            if let hit = keys.first(where: { $0.path == path }) { return hit.at }
            path.removeLast()
        }
        return nil
    }
}

/// Turns decoder errors and unknown keys into short messages for the Setup rows and the HUD.
nonisolated enum ConfigDiagnostics {
    /// What a decode error means, located in `text` when possible.
    static func issue(for error: Error, in text: String, schema: ConfigSchema = .hop) -> ConfigIssue {
        switch error {
        case DecodingError.dataCorrupted(let ctx) where ctx.codingPath.isEmpty:
            if let ns = ctx.underlyingError as NSError? { return syntaxIssue(ns, in: text) }
            return ConfigIssue(message: "Not valid JSON5")
        case DecodingError.dataCorrupted(let ctx):
            let path = components(ctx.codingPath)
            if let bad = ctx.debugDescription.firstMatch(of: /invalid String value (.*)$/)?.1,
               case .choice(let choices) = schema.node(at: path) {
                return located(path, "\"\(bad)\" is not one of \(choices.joined(separator: ", "))", in: text)
            }
            return located(path, ctx.debugDescription, in: text)
        case DecodingError.typeMismatch(let type, let ctx):
            // "found a string", but "found number": give every kind its article.
            let found = ctx.debugDescription.firstMatch(of: /found (.+) instead/).map { m in
                m.1.hasPrefix("a ") || m.1.hasPrefix("an ") || m.1 == "null" ? String(m.1) : "a \(m.1)"
            }
            return located(components(ctx.codingPath), "expected \(describe(type))" + (found.map { ", found \($0)" } ?? ""), in: text)
        case DecodingError.valueNotFound(let type, let ctx):
            return located(components(ctx.codingPath), "expected \(describe(type)), found null", in: text)
        case DecodingError.keyNotFound(let key, let ctx):
            return located(components(ctx.codingPath), "\(key.stringValue) is missing", in: text)
        default:
            return ConfigIssue(message: error.localizedDescription)
        }
    }

    /// Top-level sections hop used to read and no longer does. Old configs keep them without a
    /// warning; decoding ignores them like any unknown key. `rings` lives on the `experimental` branch.
    static let retiredKeys: Set<String> = ["rings"]

    /// Keys the config does not know, with the closest known key when it looks like a typo.
    /// They are only warnings: decoding ignores them and the rest still applies.
    static func warnings(in text: String, schema: ConfigSchema = .hop) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        for (path, at) in ConfigScan(text).keys {
            if path.count == 1, let key = path.first, retiredKeys.contains(key) { continue }
            guard case .section(let fields) = schema.node(at: Array(path.dropLast())),
                  let key = path.last, fields[key] == nil
            else { continue }
            var message = "\(display(path)) (line \(at.line)): unknown key"
            if let near = suggestion(for: key, among: Array(fields.keys)) { message += ", did you mean \(near)?" }
            issues.append(ConfigIssue(message: message, line: at.line, column: at.column))
        }
        return issues
    }

    /// The candidate a typo most likely meant: a few edits away, ignoring case.
    static func suggestion(for key: String, among candidates: [String]) -> String? {
        let scored = candidates.map { ($0, editDistance(key.lowercased(), $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }),
              best.1 <= max(2, key.count / 4)
        else { return nil }
        return best.0
    }

    /// Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let substitution = previous + (a[i - 1] == b[j - 1] ? 0 : 1)
                previous = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, substitution)
            }
        }
        return row[b.count]
    }

    // MARK: - Syntax errors

    /// The parser says e.g. "Unexpected character 's' in object around line 4, column 5."
    private static func syntaxIssue(_ error: NSError, in text: String) -> ConfigIssue {
        var reason = (error.userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
        var line: Int?, column: Int?
        if let m = reason.firstMatch(of: /\s*around line (\d+), column (\d+)\.?$/) {
            line = Int(m.1)
            column = Int(m.2)
            reason = String(reason[..<m.range.lowerBound])
        }
        if reason.hasSuffix(".") { reason.removeLast() }
        let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int
        if line == nil, let index {
            let scan = ConfigScan(text, stop: index)
            line = scan.last.map(\.at.line) ?? 1
        }

        func at(_ p: ConfigScan.Position?, _ message: String) -> ConfigIssue {
            let l = p?.line ?? line, c = p?.column ?? column
            return ConfigIssue(message: l.map { "Line \($0): \(message)" } ?? message, line: l, column: c)
        }

        if let m = reason.firstMatch(of: /^Unexpected character '(.+)' in (object|array)$/), let index {
            // The parser stops at the next token; a missing comma belongs after the previous one.
            let close = m.2 == "object" ? "}" : "]"
            switch ConfigScan(text, stop: index).last {
            case (.key, let p)?: return at(p, "expected \":\" after the key")
            case (.value, let p)?, (.punctuation("}"), let p)?, (.punctuation("]"), let p)?:
                return at(p, "expected \",\" or \"\(close)\" after a value")
            case (.punctuation(":"), _)?: return at(nil, "expected a value, found '\(m.1)'")
            default: return at(nil, m.2 == "object" ? "expected a key, found '\(m.1)'" : "expected a value, found '\(m.1)'")
            }
        }
        if let m = reason.firstMatch(of: /^Unexpected character '(.+)' after top-level value$/) {
            return at(nil, "'\(m.1)' after the config's closing }")
        }
        if reason.hasPrefix("Unexpected end of file") {
            switch ConfigScan(text).unclosed {
            case ("\"", let p)?: return at(p, "this string is never closed")
            case (let bracket, let p)?: return at(p, "the file ends before this \(bracket) is closed")
            case nil: return at(nil, "the file ends too early")
            }
        }
        if reason.contains("in expected boolean value") { return at(nil, "expected true or false") }
        if let m = reason.firstMatch(of: /^Number (.+) is not representable in Swift$/) {
            let number = String(m.1)
            return at(lineOf(number, in: text).map { ConfigScan.Position(line: $0, column: 1) },
                      "\(number) is not allowed here, use a whole number")
        }
        return at(nil, reason.prefix(1).lowercased() + reason.dropFirst())
    }

    /// First line with `token` standing on its own (not part of a longer word or number).
    private static func lineOf(_ token: String, in text: String) -> Int? {
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? line
            var rest = code[...]
            while let r = rest.range(of: token) {
                let before = r.lowerBound > code.startIndex ? code[code.index(before: r.lowerBound)] : " "
                let after = r.upperBound < code.endIndex ? code[r.upperBound] : " "
                if !(before.isLetter || before.isNumber || before == "."), !(after.isLetter || after.isNumber || after == ".") {
                    return n + 1
                }
                rest = code[r.upperBound...]
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func located(_ path: [String], _ message: String, in text: String) -> ConfigIssue {
        guard !path.isEmpty else { return ConfigIssue(message: message.prefix(1).uppercased() + message.dropFirst()) }
        let p = ConfigScan(text).position(of: path)
        let place = p.map { "\(display(path)) (line \($0.line))" } ?? display(path)
        return ConfigIssue(message: "\(place): \(message)", line: p?.line, column: p?.column)
    }

    private static func components(_ path: [CodingKey]) -> [String] {
        path.map { $0.intValue.map(String.init) ?? $0.stringValue }
    }

    /// `["bookmarks", "0", "name"]` → `bookmarks[0].name`.
    static func display(_ path: [String]) -> String {
        path.reduce(into: "") { out, key in
            if Int(key) != nil { out += "[\(key)]" } else { out += out.isEmpty ? key : ".\(key)" }
        }
    }

    private static func describe(_ type: Any.Type) -> String {
        if type == Int.self { return "a whole number" }
        if type == Double.self { return "a number" }
        if type == Bool.self { return "true or false" }
        if type == String.self { return "a string" }
        let name = String(describing: type)
        if name.hasPrefix("Array") { return "a list [ … ]" }
        if name.hasPrefix("Dictionary") { return "a section { … }" }
        return name
    }
}

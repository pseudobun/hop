import Foundation

/// `${NAME}` placeholders in the config, filled from `.env` beside it (then hop's environment),
/// so the config itself can live in a public dotfiles repo with the values kept out of it.
/// The file on disk keeps the placeholders: Settings edits write the raw text, never the values.
nonisolated enum ConfigEnv {
    /// `KEY=value` lines; `#` comments, `export `, and single or double quotes around values are fine.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// The `.env` next to `config` merged over the process environment.
    static func load(beside config: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let file = config.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: ".env")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            env.merge(parse(text)) { _, new in new }
        }
        return env
    }

    /// Replaces `${NAME}` inside string values with its value, escaped for a JSON string; comments
    /// and keys outside strings are left alone. Unknown names stay as they are and come back in `missing`.
    static func expand(_ text: String, env: [String: String]) -> (text: String, missing: [String]) {
        guard text.contains("${") else { return (text, []) }
        let c = Array(text)
        var out = "", missing: [String] = []
        var i = 0, quote: Character? = nil
        out.reserveCapacity(c.count)
        while i < c.count {
            let ch = c[i], next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if let q = quote {
                if ch == "\\", let n = next { out.append(ch); out.append(n); i += 2; continue }
                if ch == q { quote = nil }
                else if ch == "$", next == "{", let close = c[(i + 2)...].firstIndex(of: "}") {
                    let name = String(c[(i + 2)..<close])
                    if isName(name) {
                        if let value = env[name] {
                            out += value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: String(q), with: "\\" + String(q))
                        } else {
                            if !missing.contains(name) { missing.append(name) }
                            out += "${\(name)}"
                        }
                        i = close + 1
                        continue
                    }
                }
                out.append(ch); i += 1; continue
            }
            if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "/", next == "/" {
                while i < c.count, !c[i].isNewline { out.append(c[i]); i += 1 }
                continue
            } else if ch == "/", next == "*" {
                out += "/*"; i += 2
                while i < c.count, !(c[i] == "*" && i + 1 < c.count && c[i + 1] == "/") { out.append(c[i]); i += 1 }
                if i < c.count { out += "*/"; i += 2 }
                continue
            }
            out.append(ch); i += 1
        }
        return (out, missing)
    }

    private static func isName(_ s: String) -> Bool {
        guard let f = s.first, f.isLetter || f == "_" else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

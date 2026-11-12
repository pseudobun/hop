import Foundation

nonisolated struct KeePassEntry: Sendable, Equatable {
    var group: String
    var title: String
    var username: String
    var password: String
    var url: String
    var notes: String
    var totp: String

    /// Stable id for pins: group|title|username.
    var id: String { "\(group)|\(title)|\(username)" }
}

/// Parses `keepassxc-cli export -f csv` output (RFC 4180; columns mapped by header).
/// Ported from the Raycast KeePassXC extension, keeping whitespace inside fields.
nonisolated enum KeePassCSV {
    static let excludedGroups = ["Deprecated", "Recycle Bin", "Trash", "回收站"]

    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\r": continue
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func parse(_ text: String) -> [KeePassEntry] {
        let all = rows(text)
        guard let header = all.first else { return [] }
        let index = Dictionary(header.enumerated().map { ($0.element.lowercased(), $0.offset) }, uniquingKeysWith: { a, _ in a })
        func col(_ row: [String], _ name: String) -> String {
            guard let i = index[name], i < row.count else { return "" }
            return row[i]
        }
        var entries: [KeePassEntry] = []
        for row in all.dropFirst() where row.count > 1 {
            let parts = col(row, "group").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, parts.dropFirst().contains(where: { p in excludedGroups.contains { p.hasPrefix($0) } }) {
                continue
            }
            let title = col(row, "title")
            guard !title.isEmpty else { continue }
            entries.append(KeePassEntry(group: parts.dropFirst().joined(separator: "/"), title: title,
                                        username: col(row, "username"), password: col(row, "password"),
                                        url: col(row, "url"), notes: col(row, "notes"), totp: col(row, "totp")))
        }
        return entries.sorted {
            let t = $0.title.localizedCompare($1.title)
            if t != .orderedSame { return t == .orderedAscending }
            if $0.username.isEmpty != $1.username.isEmpty { return !$0.username.isEmpty }
            return $0.username.localizedCompare($1.username) == .orderedAscending
        }
    }

    static func folders(_ entries: [KeePassEntry]) -> [String] {
        Array(Set(entries.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }
}

/// KeePassXC placeholders, resolved in one case-insensitive pass (no recursion).
nonisolated enum KeePassPlaceholders {
    static func resolve(_ text: String, _ e: KeePassEntry, now: Date = Date()) -> String {
        guard text.contains("{") else { return text }
        var out = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let key = rest[rest.index(after: open)..<close].uppercased()
            let value: String? = switch key {
            case "TITLE": e.title
            case "USERNAME": e.username
            case "PASSWORD": e.password
            case "URL": e.url
            case "NOTES": e.notes
            case "TOTP": e.totp.isEmpty ? nil : try? TOTP.code(e.totp, at: now)
            default: nil
            }
            out += value ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

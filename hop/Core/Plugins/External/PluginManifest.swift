import Foundation

/// `plugin.json5` at the root of an installed plugin: who it is, the program hop runs, its
/// commands and the settings hop shows for it. See docs/plugins.md.
nonisolated struct PluginManifest: Decodable, Equatable, Sendable {
    /// Reverse DNS, unique: "dev.someone.github".
    var id: String
    var name: String
    var version: String
    var summary: String = ""
    var author: String?
    /// Lowest hop version it runs on, e.g. "0.2.0".
    var hop: String?
    /// The program, relative to the plugin folder: "bin/hop-github".
    var entry: String
    /// SF Symbol for the plugin's tile.
    var symbol: String = "puzzlepiece.extension.fill"
    /// Tile colour, "#rrggbb".
    var color: String?
    var commands: [Command] = []
    var preferences: [Preference] = []
    /// What the plugin says it does, shown before installing. hop does not enforce it.
    var permissions: Permissions = Permissions()

    nonisolated struct Command: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Sendable {
            /// Opens a list or grid the plugin fills.
            case view
            /// Runs and answers with a HUD.
            case instant
            /// Runs every `interval` with no window.
            case background
        }

        var id: String
        var title: String
        var subtitle: String?
        var kind: Kind = .view
        var keywords: [String] = []
        /// Root-search prefix that opens it, e.g. "gh ".
        var prefix: String?
        /// Background interval: "30s", "15m", "1h".
        var interval: String?
        /// SF Symbol; the plugin's own by default.
        var symbol: String?
    }

    nonisolated struct Preference: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Sendable {
            case text, secret, toggle, number, choice, list, textarea, hotkey
        }

        var id: String
        var title: String
        var type: Kind = .text
        var help: String?
        var placeholder: String?
        var `default`: JSONValue?
        var required = false
        /// Only in the config file, not on the Settings page.
        var hidden = false
        /// Values of a `choice`.
        var options: [String] = []
        var min: Int?
        var max: Int?
    }

    nonisolated struct Permissions: Decodable, Equatable, Sendable {
        /// Hosts it talks to.
        var network: [String] = []
        /// "read", "write" or "none".
        var clipboard: String = "none"
        /// Folders it reads or writes.
        var files: [String] = []
        /// Programs it runs.
        var exec: [String] = []

        var lines: [String] {
            var out: [String] = []
            if !network.isEmpty { out.append("Network: " + network.joined(separator: ", ")) }
            if clipboard != "none" { out.append("Clipboard: " + clipboard) }
            if !files.isEmpty { out.append("Files: " + files.joined(separator: ", ")) }
            if !exec.isEmpty { out.append("Runs: " + exec.joined(separator: ", ")) }
            return out
        }
    }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let s) = self { s } else { "" } }
    }

    static func decode(_ data: Data) throws -> PluginManifest {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let manifest = try decoder.decode(PluginManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// Ids, the entry path and command ids hop relies on.
    func validate() throws {
        let idPattern = /^[a-z0-9]+(\.[a-z0-9-]+){2,}$/
        guard id.wholeMatch(of: idPattern) != nil else {
            throw Problem.invalid("id \"\(id)\" must be reverse DNS in lower case, e.g. dev.you.plugin")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem.invalid("name is empty") }
        guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw Problem.invalid("entry must be a path inside the plugin folder")
        }
        var seen = Set<String>()
        for c in commands {
            guard !c.id.isEmpty, seen.insert(c.id).inserted else { throw Problem.invalid("command id \"\(c.id)\" is empty or repeated") }
            if c.kind == .background, PluginManifest.seconds(c.interval) == nil {
                throw Problem.invalid("background command \"\(c.id)\" needs an interval like \"15m\"")
            }
        }
        var prefs = Set<String>()
        for p in preferences {
            guard p.id.wholeMatch(of: /^[A-Za-z][A-Za-z0-9_]*$/) != nil, prefs.insert(p.id).inserted, p.id != "enabled" else {
                throw Problem.invalid("preference id \"\(p.id)\" is not a plain key or is repeated")
            }
        }
    }

    /// "30s", "15m", "2h" → seconds; at least 10 s.
    static func seconds(_ interval: String?) -> TimeInterval? {
        guard let interval, let unit = interval.last, let n = Double(interval.dropLast()), n > 0 else { return nil }
        let s: Double? = switch unit {
        case "s": n
        case "m": n * 60
        case "h": n * 3600
        default: nil
        }
        return s.map { max($0, 10) }
    }
}

nonisolated extension PluginManifest {
    private enum Keys: String, CodingKey {
        case id, name, version, summary, author, hop, entry, symbol, color, commands, preferences, permissions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        summary = try c.value(.summary, "")
        author = try c.decodeIfPresent(String.self, forKey: .author)
        hop = try c.decodeIfPresent(String.self, forKey: .hop)
        entry = try c.decode(String.self, forKey: .entry)
        symbol = try c.value(.symbol, "puzzlepiece.extension.fill")
        color = try c.decodeIfPresent(String.self, forKey: .color)
        commands = try c.value(.commands, [])
        preferences = try c.value(.preferences, [])
        permissions = try c.value(.permissions, Permissions())
    }
}

nonisolated extension PluginManifest.Command {
    private enum Keys: String, CodingKey { case id, title, subtitle, kind, keywords, prefix, interval, symbol }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        kind = try c.value(.kind, .view)
        keywords = try c.value(.keywords, [])
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
    }
}

nonisolated extension PluginManifest.Preference {
    private enum Keys: String, CodingKey { case id, title, type, help, placeholder, `default`, required, hidden, options, min, max }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        type = try c.value(.type, .text)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        `default` = try c.decodeIfPresent(JSONValue.self, forKey: .default)
        required = try c.value(.required, false)
        hidden = try c.value(.hidden, false)
        options = try c.value(.options, [])
        min = try c.decodeIfPresent(Int.self, forKey: .min)
        max = try c.decodeIfPresent(Int.self, forKey: .max)
    }
}

nonisolated extension PluginManifest.Permissions {
    private enum Keys: String, CodingKey { case network, clipboard, files, exec }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        network = try c.value(.network, [])
        clipboard = try c.value(.clipboard, "none")
        files = try c.value(.files, [])
        exec = try c.value(.exec, [])
    }
}

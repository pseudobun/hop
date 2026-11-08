import AppKit

/// "Theme": pick one of hop's themes; it is written to `general.theme` and hop restarts.
enum ThemeCommands {
    static func items(_ services: Services) -> [Item] {
        [
            Item(id: "system.theme", title: "Theme", subtitle: "Switch hop's look",
                 aliases: ["appearance", "colors", "dark mode", "light mode"],
                 icon: .tile("paintpalette.fill", Theme.chart5), accessory: "Command",
                 actions: [Action(title: "Choose Theme", symbol: "paintpalette") { .push(ThemeMode(services: services)) }],
                 pushesMode: true),
        ]
    }
}

final class ThemeMode: Mode {
    let title: String? = "Theme"
    let placeholder = "Search themes…"
    private let services: Services

    init(services: Services) { self.services = services }

    func sections(for query: String) -> [ResultSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let current = services.settings.data.general.theme
        let items = HopConfig.General.ThemeName.allCases.compactMap { name -> Item? in
            let spec = Theme.spec(name)
            guard q.isEmpty || spec.label.lowercased().contains(q) || name.rawValue.contains(q) else { return nil }
            return Item(id: "theme.\(name.rawValue)", title: spec.label, subtitle: spec.description,
                        icon: .tile(spec.light ? "sun.max.fill" : "moon.fill", spec.palette.primary),
                        accessory: spec.light ? "Light" : "Dark",
                        actions: [Action(title: "Use Theme", symbol: "paintpalette") { [services] in
                            Self.apply(name, services: services)
                        }],
                        tracksFrecency: false,
                        chip: name == current ? Chip(text: "Current", tone: .good) : nil)
        }
        return [ResultSection(title: nil, items: items)]
    }

    private static func apply(_ name: HopConfig.General.ThemeName, services: Services) -> ActionResult {
        let settings = services.settings
        if settings.data.general.theme == name { return .pop }
        guard let text = try? String(contentsOf: settings.url, encoding: .utf8),
              let updated = ConfigEdit.settingTheme(in: text, to: name.rawValue),
              (try? updated.write(to: settings.url, atomically: true, encoding: .utf8)) != nil
        else { return .failWithHUD("Could not write the theme to the config") }
        // The watcher would notice too; loading now restarts hop without waiting for it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            settings.load()
        }
        return .dismissWithHUD("\(Theme.spec(name).label) — restarting hop")
    }
}

/// Text edits to the JSON5 config that keep its comments and layout.
nonisolated enum ConfigEdit {
    /// Sets `general.theme`: replaces the existing value, or adds the key at the top of `general`
    /// (or a `general` block at the top of the file). nil when the file has no object to put it in.
    static func settingTheme(in text: String, to value: String) -> String? {
        let ns = text as NSString
        let existing = try! NSRegularExpression(pattern: #"^([ \t]*theme[ \t]*:[ \t]*)(["'])[^"'\n]*\2"#, options: .anchorsMatchLines)
        if let m = existing.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return ns.replacingCharacters(in: m.range, with: ns.substring(with: m.range(at: 1)) + "\"\(value)\"")
        }
        let general = try! NSRegularExpression(pattern: #"^([ \t]*)general[ \t]*:[ \t]*\{[ \t]*\n"#, options: .anchorsMatchLines)
        if let m = general.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let indent = ns.substring(with: m.range(at: 1)) + "  "
            return ns.replacingCharacters(in: NSRange(location: m.range.upperBound, length: 0), with: "\(indent)theme: \"\(value)\",\n")
        }
        guard let brace = text.firstIndex(of: "{") else { return nil }
        var out = text
        out.insert(contentsOf: "\n  general: { theme: \"\(value)\" },", at: out.index(after: brace))
        return out
    }
}

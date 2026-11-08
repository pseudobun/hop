import AppKit

/// "Theme": pick one of hop's themes. The selected row previews it live; ↵ writes it to
/// `general.theme`, where the config watcher applies it everywhere.
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

    /// Leaving without picking goes back to the saved theme.
    func didExit() { services.previewTheme?(services.settings.data.general.theme) }

    func selectionDidChange(_ item: Item?) {
        guard let id = item?.id, id.hasPrefix("theme."),
              let name = HopConfig.General.ThemeName(rawValue: String(id.dropFirst("theme.".count)))
        else { return }
        services.previewTheme?(name)
    }

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
        if settings.data.general.theme == name { return .dismiss }
        guard settings.update(["general", "theme"], to: ConfigEdit.literal(name.rawValue))
        else { return .failWithHUD("Could not write the theme to the config") }
        return .dismissWithHUD("Theme: \(Theme.spec(name).label)")
    }
}

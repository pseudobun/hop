import Foundation

nonisolated extension HopConfig {
    /// A link searchable from the root, opened in the default browser.
    nonisolated struct Bookmark: Decodable, Equatable, Sendable {
        var name = ""
        var url = ""
        /// Other names that find it, e.g. "hass" for Home Assistant.
        var aliases: [String] = []
        /// Image file (absolute, ~/ or relative to the config folder), SF Symbol name or emoji.
        var icon = ""
        /// Tile colour for an SF Symbol icon, "#rrggbb".
        var color = ""
        /// Shown next to the name; defaults to the URL without its scheme.
        var subtitle = ""
    }

    /// `bookmarks: [ … ]`: the section is a list.
    nonisolated struct Bookmarks: PluginConfig {
        static let key = "bookmarks"
        var items: [Bookmark] = []
        static var samples: [String: Any] { ["": Bookmark()] }
        var reflected: Any { items }
        init() {}
        init(from decoder: Decoder) throws { items = try decoder.singleValueContainer().decode([Bookmark].self) }
    }

    var bookmarks: [Bookmark] {
        get { sections[Bookmarks.self].items }
        set { sections[Bookmarks.self].items = newValue }
    }
}

nonisolated extension HopConfig.Bookmark {
    private enum Keys: String, CodingKey { case name, url, aliases, icon, color, subtitle }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        name = try c.value(.name, d.name)
        url = try c.value(.url, d.url)
        aliases = try c.value(.aliases, d.aliases)
        icon = try c.value(.icon, d.icon)
        color = try c.value(.color, d.color)
        subtitle = try c.value(.subtitle, d.subtitle)
    }
}

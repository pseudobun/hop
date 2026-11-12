import AppKit

/// Bookmarks: links from the config, searchable from the root.
final class BookmarksPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "bookmarks", name: "Bookmarks", summary: "Links you can search from hop.", symbol: "bookmark.fill",
                   color: Theme.chart1, category: .integrations)
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .info(SettingsInfo(
                    label: "Bookmarks",
                    help: "Name, URL, aliases, icon and colour of each live in the config.",
                    lines: { config in config.bookmarks.map { "\($0.name)  ·  \($0.url)" } },
                    button: "Edit in Config", action: .openConfig)),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { BookmarkCommands.items(host!.services) }
}

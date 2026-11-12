import AppKit

/// File search over Spotlight's index; `f ` and paths (`~/…`) open it.
final class FilesPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "files", name: "Files", summary: "File search with Spotlight's index.", symbol: "folder.fill",
                   color: Palette.files, category: .tools, enabledPath: ["files", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("files.enabled", "File search", .toggle),
                .setting("files.scopes", "Search in", .list(placeholder: "~"), "Folders, comma-separated.", check: SettingsChecks.folders),
                .setting("files.exclude", "Hide paths with", .list(placeholder: "node_modules, .git"), "Folder names anywhere in a result's path."),
                .setting("files.contentSearch", "Search file contents", .toggle, "Also find files by the text inside them."),
                .setting("files.maxResults", "At most", .number(min: 1, max: 1_000, unit: "results")),
                .setting("files.showHidden", "Show dotfiles", .toggle, "When browsing a path (~/…)."),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    private func mode() -> Mode {
        FileSearchMode(settings: host!.settings, frecency: host!.services.frecency)
    }

    func commands() -> [Item] { FileCommands.items(host!.services) }
    func prefixModes() -> [PrefixMode] { [PrefixMode(prefix: "f ") { [unowned self] in mode() }] }
    func pathMode() -> Mode? { mode() }
}

import AppKit

/// System commands: Empty Trash, Clear Downloads, Kill Process, Uninstall.
final class SystemPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "system", name: "System", summary: "Trash, Downloads, processes and uninstalling apps.", symbol: "desktopcomputer",
                   color: Palette.neutral, category: .system)
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("system.downloadsFolder", "Downloads folder", .text(placeholder: "~/Downloads"), "Emptied by \"Clear Downloads\"."),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { SystemCommands.items(host!.services) }

    func appActions(_ entry: AppEntry) -> [Action] {
        guard entry.kind == .application, UninstallMode.isRemovable(entry.path) else { return [] }
        return [Action(title: "Uninstall…", style: .destructive) { .push(UninstallMode(app: entry)) }]
    }
}

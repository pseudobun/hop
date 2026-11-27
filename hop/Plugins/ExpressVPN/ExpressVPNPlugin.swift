import AppKit

/// ExpressVPN: connect, disconnect and pick a region (through `expressvpnctl`).
final class ExpressVPNPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "expressvpn", name: "ExpressVPN", summary: "Connect, disconnect and pick a region.",
                   symbol: "lock.shield.fill", color: Palette.expressvpn, category: .integrations, keywords: ["vpn"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("expressvpn.showFlags", "Flags", .toggle, "A country flag next to each region."),
                .setting("expressvpn.favorites", "Favorites", .list(placeholder: "slovenia"),
                         "Regions on top of the list, in order: \"slovenia\", \"germany-frankfurt-1\"; `hop vpn regions` lists them."),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { ExpressVPNCommands.items(host!.services) }
}

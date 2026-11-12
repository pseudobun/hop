import AppKit

/// WireGuard tunnels in the launcher and as a bar of pills under the search field.
final class WireGuardPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "wireguard", name: "WireGuard", summary: "Tunnels in the launcher and in the bar under it.",
                   symbol: "network.badge.shield.half.filled", color: Palette.wireguard, category: .integrations,
                   enabledPath: ["wireguard", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("wireguard.enabled", "WireGuard", .toggle),
                .setting("wireguard.showFlags", "Flags", .toggle, "From a tunnel name prefix: \"si-home\" → 🇸🇮."),
                .setting("wireguard.exclusive", "One tunnel at a time", .toggle, "Activating a tunnel deactivates the others first."),
            ]),
            SettingsSection("Bar", [
                .setting("wireguard.bar", "Tunnel bar", .toggle, "Tunnels as pills under the search field; click one to toggle it."),
                .setting("wireguard.barTunnels", "Tunnels in the bar", .list(placeholder: "all"), "Names in order; empty shows every tunnel."),
                .setting("wireguard.keys.focus", "Select in the bar", .hotkey(optional: true), "In the launcher: ←→ move, ↵ toggles, Esc goes back."),
                .setting("wireguard.keys.disconnectAll", "Disconnect all", .hotkey(optional: true)),
                .setting("wireguard.keys.direct", "Toggle with 1…9", .text(placeholder: "alt+cmd"), "Modifiers for 1…9 that toggle a tunnel at once; empty is off.", check: SettingsChecks.modifiers),
            ]),
        ]
    }

    init() {}

    private(set) var bar: WireGuardBar?
    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        let settings = host.settings
        let bar = WireGuardBar()
        bar.config = { settings.data.wireguard }
        bar.onShowAll = { [weak host] in
            let wg = settings.data.wireguard
            host?.launcher.push(WireGuardMode(showFlags: wg.showFlags, sensitivity: settings.data.general.sensitivity,
                                              exclusive: wg.exclusive))
        }
        host.launcher.setStrip(bar)
        self.bar = bar
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "DebugWireGuardFocus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { bar.debugFocus() }
        }
        #endif
    }

    func commands() -> [Item] { WireGuardCommands.items(host!.services) }
    func themeDidChange(saved: Bool) { bar?.retheme() }
}

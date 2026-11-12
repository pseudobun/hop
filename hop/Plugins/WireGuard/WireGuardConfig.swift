import Foundation

nonisolated extension HopConfig {
    nonisolated struct WireGuard: PluginConfig {
        static let key = "wireguard"
        var enabled = true
        var showFlags = true
        /// Activating a tunnel deactivates the others first.
        var exclusive = true
        /// Tunnels as pills under the root search field.
        var bar = true
        /// Names shown in the bar, in this order; empty shows every tunnel.
        var barTunnels: [String] = []
        var keys = Keys()

        /// Launcher keys for the bar, in hotkey syntax ("cmd+j"); "" turns one off.
        nonisolated struct Keys: Decodable, Equatable, Sendable {
            /// Moves the keys into the bar: ←→ select, ↵ toggles, Esc back.
            var focus = "cmd+j"
            var disconnectAll = "cmd+shift+j"
            /// Modifiers for 1…9 that toggle a tunnel straight away, e.g. "alt+cmd"; "" = off.
            var direct = ""
        }
    }

    var wireguard: WireGuard {
        get { sections[WireGuard.self] }
        set { sections[WireGuard.self] = newValue }
    }
}

nonisolated extension HopConfig.WireGuard {
    private enum Fields: String, CodingKey { case enabled, showFlags, exclusive, bar, barTunnels, keys }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Fields.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        showFlags = try c.value(.showFlags, d.showFlags)
        exclusive = try c.value(.exclusive, d.exclusive)
        bar = try c.value(.bar, d.bar)
        barTunnels = try c.value(.barTunnels, d.barTunnels)
        keys = try c.value(.keys, d.keys)
    }
}

nonisolated extension HopConfig.WireGuard.Keys {
    private enum Keys: String, CodingKey { case focus, disconnectAll, direct }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        focus = try c.value(.focus, d.focus)
        disconnectAll = try c.value(.disconnectAll, d.disconnectAll)
        direct = try c.value(.direct, d.direct)
    }
}

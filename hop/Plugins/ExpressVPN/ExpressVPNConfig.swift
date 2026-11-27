import Foundation

nonisolated extension HopConfig {
    nonisolated struct ExpressVPN: PluginConfig {
        static let key = "expressvpn"
        /// A flag next to each region.
        var showFlags = true
        /// Regions listed first, in this order: slugs ("slovenia") or names ("UK London").
        var favorites: [String] = []
    }

    var expressvpn: ExpressVPN {
        get { sections[ExpressVPN.self] }
        set { sections[ExpressVPN.self] = newValue }
    }
}

nonisolated extension HopConfig.ExpressVPN {
    private enum Keys: String, CodingKey { case showFlags, favorites }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        showFlags = try c.value(.showFlags, d.showFlags)
        favorites = try c.value(.favorites, d.favorites)
    }
}

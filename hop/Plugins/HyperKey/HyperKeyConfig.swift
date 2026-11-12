import Foundation

nonisolated extension HopConfig {
    nonisolated struct HyperKey: PluginConfig {
        static let key = "hyperKey"
        var enabled = false
        /// Caps Lock pressed and released alone sends Escape.
        var quickPressEscape = false
    }

    var hyperKey: HyperKey {
        get { sections[HyperKey.self] }
        set { sections[HyperKey.self] = newValue }
    }
}

nonisolated extension HopConfig.HyperKey {
    private enum Keys: String, CodingKey { case enabled, quickPressEscape }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        quickPressEscape = try c.value(.quickPressEscape, d.quickPressEscape)
    }
}

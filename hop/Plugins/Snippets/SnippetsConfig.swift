import Foundation

nonisolated extension HopConfig {
    nonisolated struct Snippets: PluginConfig {
        static let key = "snippets"
        var enabled = true
        /// Replace a snippet's keyword with the snippet as soon as it is typed (Accessibility).
        var expand = true
        /// Also expand keywords typed in the middle of a word.
        var expandWithinWords = false
        /// Apps where keywords never expand (bundle identifiers).
        var disabledApps: [String] = []
        var file = "~/.config/hop/snippets.json5"
    }

    var snippets: Snippets {
        get { sections[Snippets.self] }
        set { sections[Snippets.self] = newValue }
    }
}

nonisolated extension HopConfig.Snippets {
    private enum Keys: String, CodingKey { case enabled, expand, expandWithinWords, disabledApps, file }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        expand = try c.value(.expand, d.expand)
        expandWithinWords = try c.value(.expandWithinWords, d.expandWithinWords)
        disabledApps = try c.value(.disabledApps, d.disabledApps)
        file = try c.value(.file, d.file)
    }
}

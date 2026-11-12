import Foundation

nonisolated extension HopConfig {
    nonisolated struct Translate: PluginConfig {
        static let key = "translate"
        var enabled = true
        /// Translations are rare and should read well: a strong model, not the cheapest.
        var model = "gpt-6.1-terra"
        /// reasoning_effort; "" leaves it out.
        var reasoning = "none"
        /// Two ISO 639 codes: text in the first goes to the second, anything else to the first.
        /// Empty: the macOS language and English.
        var languages: [String] = []
    }

    var translate: Translate {
        get { sections[Translate.self] }
        set { sections[Translate.self] = newValue }
    }
}

nonisolated extension HopConfig.Translate {
    private enum Keys: String, CodingKey { case enabled, model, reasoning, languages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        model = try c.value(.model, d.model)
        reasoning = try c.value(.reasoning, d.reasoning)
        languages = try c.value(.languages, d.languages)
    }
}

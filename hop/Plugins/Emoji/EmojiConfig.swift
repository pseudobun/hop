import Foundation

nonisolated extension HopConfig {
    nonisolated struct Emoji: PluginConfig {
        static let key = "emoji"
        var enabled = true
        /// none, light, mediumLight, medium, mediumDark or dark; for emoji that take one.
        var skinTone = "none"
        /// Ask OpenAI for emoji when the index finds little (needs a key: "Set OpenAI API Key").
        var ai = true
        /// The cheapest current model is plenty for picking emoji.
        var aiModel = "gpt-6-luna"
        /// reasoning_effort ("none" answers in about 1.5 s); "" omits it.
        var aiReasoning = "none"
    }

    var emoji: Emoji {
        get { sections[Emoji.self] }
        set { sections[Emoji.self] = newValue }
    }
}

nonisolated extension HopConfig.Emoji {
    private enum Keys: String, CodingKey { case enabled, skinTone, ai, aiModel, aiReasoning }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        skinTone = try c.value(.skinTone, d.skinTone)
        ai = try c.value(.ai, d.ai)
        aiModel = try c.value(.aiModel, d.aiModel)
        aiReasoning = try c.value(.aiReasoning, d.aiReasoning)
    }
}

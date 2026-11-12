import AppKit

/// Emoji search by name, slang or in Slovenian; ":" in root search opens it.
final class EmojiPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "emoji", name: "Emoji", summary: "Search Emoji, or type \":\" in hop.", symbol: "face.smiling.inverse",
                   color: Palette.emoji, category: .ai, enabledPath: ["emoji", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("emoji.enabled", "Emoji search", .toggle),
                .setting("emoji.skinTone", "Skin tone", .choice([
                    ("none", "None"), ("light", "Light"), ("mediumLight", "Medium light"), ("medium", "Medium"),
                    ("mediumDark", "Medium dark"), ("dark", "Dark"),
                ]), "For emoji that take one."),
            ]),
            SettingsSection("AI suggestions", [
                .setting("emoji.ai", "Ask OpenAI", .toggle, "For phrases the index can't place; only with a key (\"Set OpenAI API Key\")."),
                .setting("emoji.aiModel", "Model", .text(placeholder: "gpt-6-luna")),
                .setting("emoji.aiReasoning", "Reasoning effort", .text(placeholder: "none"), "\"none\" answers in about 1.5 s; empty leaves it out."),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { EmojiCommands.items(host!.services) }

    func prefixModes() -> [PrefixMode] {
        // ":" like Slack and GitHub shortcodes: ":fire" searches emoji for "fire".
        [PrefixMode(prefix: ":") { [unowned self] in EmojiCommands.mode(host!.services) }]
    }
}

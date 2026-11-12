import AppKit

/// Translation between two languages with OpenAI; "tr " in root search opens it.
final class TranslatePlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "translate", name: "Translate", summary: "\"tr \" in hop: between two languages with OpenAI.",
                   symbol: "character.bubble.fill", color: Palette.translate, category: .ai, enabledPath: ["translate", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("translate.enabled", "Translate", .toggle),
                .setting("translate.languages", "Languages", .list(placeholder: "de, en"),
                  "Two ISO 639 codes: text in the first goes to the second, anything else to the first. Empty: your macOS language and English.",
                  check: SettingsChecks.languagePair),
                .setting("translate.model", "Model", .text(placeholder: "gpt-6.1-terra")),
                .setting("translate.reasoning", "Reasoning effort", .text(placeholder: "none"), "\"none\", \"low\", …; empty leaves it out."),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { TranslateCommands.items(host!.services) }

    func prefixModes() -> [PrefixMode] {
        // "tr hvala za vse" opens Translate with that text.
        [PrefixMode(prefix: "tr ") { [unowned self] in TranslateCommands.mode(host!.services) }]
    }
}

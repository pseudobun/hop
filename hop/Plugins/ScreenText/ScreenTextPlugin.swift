import AppKit

/// Copy Text from Screen: recognise text in a screen area on this Mac.
final class ScreenTextPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "ocr", name: "Screen Text", summary: "Copy Text from Screen, read on this Mac.", symbol: "text.viewfinder",
                   color: Palette.ocr, category: .ai, enabledPath: ["ocr", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("ocr.enabled", "Copy Text from Screen", .toggle),
                .setting("ocr.languages", "Languages", .list(placeholder: "en-US, sl-SI"), "Vision recognition languages, most likely first."),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func commands() -> [Item] { ScreenTextCommands.items(host!.services) }
}

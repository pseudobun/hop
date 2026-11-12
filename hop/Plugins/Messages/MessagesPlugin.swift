import AppKit

/// Verification codes from SMS and iMessage: list, paste, copy as they arrive.
final class MessagesPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "messages", name: "Messages", summary: "Verification codes from SMS and iMessage.", symbol: "message.fill",
                   color: Palette.messages, category: .integrations, enabledPath: ["messages", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("messages.enabled", "Messages codes", .toggle, "Needs Full Disk Access."),
                .setting("messages.pasteHotkey", "Paste latest code", .hotkey(optional: true)),
                .setting("messages.notify", "Notify", .toggle, "A HUD when a new code arrives."),
                .setting("messages.autoCopy", "Copy new codes", .toggle, "Hidden from clipboard history, cleared after 2 minutes."),
                .setting("messages.days", "List codes from the last", .number(min: 1, max: 365, unit: "days")),
                .setting("messages.latestMinutes", "Latest code within", .number(min: 1, max: 1_440, unit: "min"),
                  "\"Paste Latest Code\" takes only a code this recent."),
            ]),
        ]
    }

    init() {}

    private let watcher = MessageCodeWatcher()
    private weak var host: PluginHost?

    func start(_ host: PluginHost) { self.host = host }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        if previous?.messages != config.messages { watcher.apply(config.messages) }
    }

    func commands() -> [Item] { MessagesCommands.items(host!.services) }

    func hotkeys(_ config: HopConfig) -> [PluginHotkey] {
        let minutes = config.messages.latestMinutes
        return [PluginHotkey(owner: "messages.pasteHotkey", spec: config.messages.pasteHotkey) { [weak self] in
            Task {
                let result = await MessagesCommands.pasteLatest(within: minutes) { self?.host?.launcher.hide() }
                result.showHUD()
            }
        }]
    }

    func stop() { watcher.stop() }
}

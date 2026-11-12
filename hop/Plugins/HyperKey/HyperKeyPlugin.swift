import AppKit

/// Caps Lock as Hyper (⌃⌥⌘⇧), with an optional tap for Escape.
final class HyperKeyPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "hyperKey", name: "Hyper Key", summary: "Caps Lock as ⌃⌥⌘⇧.", symbol: "capslock.fill",
                   color: Theme.chart3, category: .keyboard, enabledPath: ["hyperKey", "enabled"], enabledByDefault: false)
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("hyperKey.enabled", "Caps Lock is Hyper", .toggle, "Needs Accessibility permission."),
                .setting("hyperKey.quickPressEscape", "Tap for Escape", .toggle, "Caps Lock pressed and released on its own sends Escape."),
            ]),
        ]
    }

    init() {}

    let controller = HyperKeyController()

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        if previous?.hyperKey != config.hyperKey {
            controller.update(enabled: config.hyperKey.enabled, quickPressEscape: config.hyperKey.quickPressEscape)
        }
    }

    func stop() { controller.stop() }
}

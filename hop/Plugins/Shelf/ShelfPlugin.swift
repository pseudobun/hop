import AppKit

/// Shelves: park files, links, images and text while dragging.
final class ShelfPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "shelf", name: "Shelf", summary: "Park files, links, images and text while you drag.", symbol: "tray.fill",
                   color: Palette.shelf, category: .tools, enabledPath: ["shelf", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("shelf.enabled", "Shelves", .toggle),
                .setting("shelf.shake", "Shake to open", .toggle, "Shake the pointer while dragging to open a shelf under it."),
                .setting("shelf.shakeSensitivity", "Shake sensitivity", .choices(ShakeDetector.Sensitivity.choices), "How small a shake counts."),
                .setting("shelf.modifier", "Hold while dragging", .text(placeholder: "shift"), "\"shift\", \"alt\", \"ctrl+alt\"; empty turns it off.", check: SettingsChecks.modifiers),
                .setting("shelf.keepAfterDragOut", "Keep dragged-out items", .toggle),
                .setting("shelf.ignoreApps", "Never open for", .list(placeholder: "com.apple.finder"), "Drags from these apps (bundle identifiers).", check: SettingsChecks.bundleIDs),
            ]),
            SettingsSection("Hotkeys", [
                .setting("shelf.hotkey", "New shelf", .hotkey(optional: true)),
                .setting("shelf.clipboardHotkey", "New shelf from clipboard", .hotkey(optional: true)),
                .setting("shelf.reopenHotkey", "Reopen last shelf", .hotkey(optional: true)),
            ]),
        ]
    }

    init() {}

    private(set) var controller: ShelfController!
    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        controller = ShelfController(settings: host.settings)
        controller.onChange = { [weak host] in host?.rebuildRoot() }
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        if previous?.shelf != config.shelf { controller.apply(config.shelf) }
    }

    func commands() -> [Item] { ShelfCommands.items(host!.services) }

    func hotkeys(_ config: HopConfig) -> [PluginHotkey] {
        [
            PluginHotkey(owner: "shelf.hotkey", spec: config.shelf.hotkey) { [weak self] in self?.controller.newShelf() },
            PluginHotkey(owner: "shelf.clipboardHotkey", spec: config.shelf.clipboardHotkey) { [weak self] in
                self?.controller.newShelfFromClipboard()
            },
            PluginHotkey(owner: "shelf.reopenHotkey", spec: config.shelf.reopenHotkey) { [weak self] in self?.controller.reopenLast() },
        ]
    }

    func bindings() -> [PluginBinding] {
        [
            PluginBinding(names: ["shelf.new", "new shelf", "shelf"]) { [weak self] in self?.controller.newShelf() },
            PluginBinding(names: ["shelf.clipboard", "new shelf from clipboard"]) { [weak self] in self?.controller.newShelfFromClipboard() },
            PluginBinding(names: ["shelf.reopen", "reopen shelf"]) { [weak self] in self?.controller.reopenLast() },
        ]
    }

    func stop() { controller?.saveNow() }
}

extension Services {
    var shelves: ShelfController? { plugin(ShelfPlugin.self)?.controller }
}

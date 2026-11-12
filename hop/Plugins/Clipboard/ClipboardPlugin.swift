import AppKit

/// Clipboard history: a floating window over everything copied.
final class ClipboardPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "clipboard", name: "Clipboard", summary: "History of what you copy.", symbol: "doc.on.clipboard.fill",
                   color: Palette.clipboard, category: .tools, enabledPath: ["clipboard", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("clipboard.enabled", "Clipboard history", .toggle),
                .setting("clipboard.hotkey", "Hotkey", .hotkey(optional: false), "Opens the history from anywhere."),
                .setting("clipboard.pasteOnReturn", "↵ pastes", .toggle, "Paste into the app you were in; off only copies."),
            ]),
            SettingsSection("Storage", [
                .setting("clipboard.keepDays", "Keep for", .number(min: -1, max: 36_500, unit: "days"), "Unpinned entries; -1 keeps them forever."),
                .setting("clipboard.maxItems", "At most", .number(min: 1, max: 100_000, unit: "items")),
                .setting("clipboard.images", "Keep images", .toggle),
                .setting("clipboard.maxImageMB", "Largest image", .number(min: 1, max: 1_000, unit: "MB")),
            ]),
            SettingsSection("Privacy", [
                .setting("clipboard.ignoreApps", "Never record from", .list(placeholder: "com.1password.1password"),
                  "Bundle identifiers. Copies marked concealed (KeePassXC, 1Password, hop) are skipped anyway.",
                  check: SettingsChecks.bundleIDs),
                .setting("clipboard.cliAccess", "Allow `hop clip`", .toggle, "Lets the CLI (and agents) read the history; it holds whatever you copied."),
            ]),
        ]
    }

    init() {}

    private(set) var store: ClipboardStore!
    private(set) var monitor: ClipboardMonitor!
    private(set) var controller: ClipboardController!
    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        var dir = AppPaths.file("Clipboard")
        #if DEBUG
        if let debugDir = UserDefaults.standard.string(forKey: "DebugClipboardDir") { dir = URL(fileURLWithPath: debugDir) }
        #endif
        store = ClipboardStore(dir: dir)
        store.load()
        let settings = host.settings
        monitor = ClipboardMonitor(store: store) { settings.data.clipboard }
        makeController()
    }

    private func makeController() {
        guard let host else { return }
        controller = ClipboardController(store: store, monitor: monitor, settings: host.settings)
        controller.saveSnippet = { [weak host] text in
            guard let file = host?.plugin(SnippetsPlugin.self)?.service?.file else { return false }
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return file.append(Snippet(name: String(first.trimmingCharacters(in: .whitespaces).prefix(40)), text: text))
        }
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        guard previous?.clipboard != config.clipboard else { return }
        if config.clipboard.enabled {
            monitor.start()
            store.prune(keepDays: config.clipboard.keepDays, maxItems: config.clipboard.maxItems)
        } else {
            monitor.stop()
            controller.hide()
        }
    }

    func commands() -> [Item] { ClipboardCommands.items(host!.services) }

    func hotkeys(_ config: HopConfig) -> [PluginHotkey] {
        [PluginHotkey(owner: "the clipboard hotkey", spec: config.clipboard.hotkey) { [weak self] in self?.toggle() }]
    }

    func bindings() -> [PluginBinding] {
        [PluginBinding(names: ["clipboard.history", "clipboard history", "clipboard"]) { [weak self] in self?.toggle() }]
    }

    private func toggle() {
        host?.launcher.hide()
        controller.toggle()
    }

    func setAway(_ away: Bool) { monitor.isPaused = away }

    func themeDidChange(saved: Bool) {
        guard saved else { return }
        let shown = controller.isVisible
        controller.hide()
        makeController()
        if shown { controller.show() }
    }

    func stop() { store?.saveNow() }
}

extension Services {
    var clipboard: ClipboardController? { plugin(ClipboardPlugin.self)?.controller }
}

import AppKit
import os

/// The loaded plugins: starts them, hands them config changes, registers their hotkeys and
/// collects what they add to root search.
final class PluginManager {
    private(set) var plugins: [any HopPlugin]
    private var enabledIDs: Set<String> = []
    /// Registered plugin hotkeys by "plugin/owner", with the spec they were registered for.
    private var hotkeys: [String: (spec: String, hotkey: GlobalHotkey)] = [:]
    /// Plugin hotkeys that could not be set up, for the root's "Hotkeys need attention" row.
    private(set) var hotkeyProblems: [String] = []

    init(plugins: [any HopPlugin]) {
        self.plugins = plugins
    }

    var enabled: [any HopPlugin] { plugins.filter { enabledIDs.contains($0.info.id) } }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func plugin<P: HopPlugin>(_ type: P.Type) -> P? {
        plugins.lazy.compactMap { $0 as? P }.first
    }

    func plugin(id: String) -> (any HopPlugin)? { plugins.first { $0.info.id == id } }

    func start(_ host: PluginHost) {
        for plugin in plugins { plugin.start(host) }
    }

    /// Adds a plugin after launch (one just installed) and applies the current config to it.
    func add(_ plugin: any HopPlugin, host: PluginHost) {
        plugins.removeAll { $0.info.id == plugin.info.id }
        plugins.append(plugin)
        plugin.start(host)
        let config = host.settings.data
        let on = plugin.info.isEnabled(in: config)
        if on { enabledIDs.insert(plugin.info.id) } else { enabledIDs.remove(plugin.info.id) }
        plugin.apply(config, previous: nil, enabled: on)
        registerHotkeys(config)
    }

    func remove(id: String) {
        guard let plugin = plugin(id: id) else { return }
        plugin.apply(HopConfig(), previous: nil, enabled: false)
        plugin.stop()
        plugins.removeAll { $0.info.id == id }
        enabledIDs.remove(id)
        for key in hotkeys.keys where key.hasPrefix(id + "/") {
            hotkeys[key]?.hotkey.unregister()
            hotkeys[key] = nil
        }
    }

    /// The config was loaded or changed: every plugin learns whether it is on and gets the
    /// new values; hotkeys follow.
    func apply(_ config: HopConfig, previous: HopConfig?) {
        for plugin in plugins {
            let on = plugin.info.isEnabled(in: config)
            if on { enabledIDs.insert(plugin.info.id) } else { enabledIDs.remove(plugin.info.id) }
            plugin.apply(config, previous: previous, enabled: on)
        }
        registerHotkeys(config)
    }

    private func registerHotkeys(_ config: HopConfig) {
        var wanted: [String: PluginHotkey] = [:]
        for plugin in enabled {
            for hotkey in plugin.hotkeys(config) where !hotkey.spec.isEmpty {
                wanted["\(plugin.info.id)/\(hotkey.owner)"] = hotkey
            }
        }
        for (key, entry) in hotkeys where wanted[key]?.spec != entry.spec {
            entry.hotkey.unregister()
            hotkeys[key] = nil
        }
        var problems: [String] = []
        for (key, want) in wanted.sorted(by: { $0.key < $1.key }) {
            guard hotkeys[key] == nil else { continue }
            guard let parsed = HotkeySpec.parse(want.spec) else {
                Log.app.error("Invalid hotkey \(want.spec, privacy: .public) for \(want.owner, privacy: .public)")
                problems.append("\(want.owner): \"\(want.spec)\" is not a hotkey")
                continue
            }
            let action = want.action
            let hotkey = GlobalHotkey { action() }
            if hotkey.register(keyCode: parsed.keyCode, modifiers: parsed.modifiers) {
                hotkeys[key] = (want.spec, hotkey)
            } else {
                Log.app.error("Could not register \(want.owner, privacy: .public) \(want.spec, privacy: .public)")
                problems.append("\(want.owner): \(want.spec) is taken")
            }
        }
        // Kept from earlier applies: still registered, so no problem.
        hotkeyProblems = problems
    }

    /// Hotkeys the plugins hold, so a `hotkeys` binding can't take one twice.
    func reservedHotkeys(_ config: HopConfig) -> [(owner: String, hotkey: String)] {
        enabled.flatMap { $0.hotkeys(config) }.filter { !$0.spec.isEmpty }.map { (owner: $0.owner, hotkey: $0.spec) }
    }

    // MARK: Root search

    func commands() -> [Item] { enabled.flatMap { $0.commands() } }
    func prefixModes() -> [PrefixMode] { enabled.flatMap { $0.prefixModes() } }
    func upcomingItems() -> [Item] { enabled.flatMap { $0.upcomingItems() } }
    func pathMode() -> Mode? { enabled.lazy.compactMap { $0.pathMode() }.first }
    func appActions(_ entry: AppEntry) -> [Action] { enabled.flatMap { $0.appActions(entry) } }

    func answer(for query: String, isAmbiguous: Bool) -> ResultSection? {
        enabled.lazy.compactMap { $0.answer(for: query, isAmbiguous: isAmbiguous) }.first
    }

    /// The binding a `hotkeys` key names, e.g. "notes.new" or "New Note".
    func binding(named name: String) -> PluginBinding? {
        let lower = name.lowercased()
        return enabled.lazy.flatMap { $0.bindings() }.first { $0.names.contains(lower) }
    }

    // MARK: Lifecycle

    func launcherWillShow() { for p in enabled { p.launcherWillShow() } }
    func setAway(_ away: Bool) { for p in plugins { p.setAway(away) } }
    func themeDidChange(saved: Bool) { for p in plugins { p.themeDidChange(saved: saved) } }
    func stop() { for p in plugins { p.stop() } }

    // MARK: Settings

    /// Every plugin's Settings page, built-in ones first.
    var pages: [SettingsPage] { plugins.map { $0.info.page($0.settings) } }
}

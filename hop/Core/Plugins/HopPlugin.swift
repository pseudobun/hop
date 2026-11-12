import AppKit

/// Who stands behind a plugin.
enum PluginTier: String, Sendable {
    /// Compiled into hop from this repository.
    case builtin
    /// Installed from GitHub and listed in hop's plugin index (pinned hash).
    case verified
    /// Installed from any GitHub link.
    case community

    var label: String {
        switch self {
        case .builtin: "Built-in"
        case .verified: "Verified"
        case .community: "Community"
        }
    }
}

/// Where a plugin's page sits in the Settings sidebar.
enum PluginCategory: String, CaseIterable, Sendable {
    case keyboard = "Keyboard"
    case tools = "Tools"
    case ai = "AI"
    case integrations = "Integrations"
    case system = "System"
    case installed = "Installed"
}

/// What hop shows about a plugin: the Plugins list, its Settings page, its commands' tint.
struct PluginInfo {
    /// Stable id: the config section key for built-in plugins ("notes"), reverse DNS for
    /// installed ones ("dev.someone.github").
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let color: NSColor
    var category: PluginCategory
    var tier: PluginTier = .builtin
    var version: String?
    var author: String?
    /// The GitHub repository an installed plugin came from.
    var source: String?
    /// Config key path of the plugin's own on/off switch (`["notes", "enabled"]`); nil keeps it
    /// in `plugins.disabled`.
    var enabledPath: [String]?
    /// On when the config says nothing.
    var enabledByDefault = true
    /// Words that find the plugin in Settings search besides its name and summary.
    var keywords: [String] = []
}

/// A global hotkey a plugin owns, e.g. the Notes window's "alt+.".
struct PluginHotkey {
    /// Config key named in problems and conflicts: "notes.hotkey".
    let owner: String
    /// Hotkey syntax; "" is off.
    let spec: String
    let action: () -> Void
}

/// A name the `hotkeys` config can bind (`"New Note": "hyper+n"`) to something that is not a
/// root command, e.g. opening a window.
struct PluginBinding {
    /// Names matched case-insensitively: an id ("notes.new") and titles ("new note").
    let names: [String]
    let action: () -> Void
}

/// A root-search prefix that opens a plugin's mode: "kp " → KeePassXC.
struct PrefixMode {
    let prefix: String
    let make: () -> Mode
}

/// What hop offers a plugin.
protocol PluginHost: AnyObject {
    var services: Services { get }
    var settings: AppSettings { get }
    var launcher: LauncherController { get }
    /// Screen locked, asleep or another user in front.
    var isAway: Bool { get }
    /// Root commands or items changed: rebuild the root search.
    func rebuildRoot()
    /// Re-run the launcher's query if it is on screen.
    func reloadLauncher()
    /// Shows the launcher with `mode` pushed.
    func present(_ mode: Mode)
    func openSettings(_ page: String?)
    func openConfig()
    /// Another plugin, when it is compiled in.
    func plugin<P: HopPlugin>(_ type: P.Type) -> P?
}

/// A feature of hop: its commands, modes, hotkeys, settings and background work. Built-in
/// plugins conform directly (`BuiltinPlugin`); plugins installed from GitHub run as their own
/// process behind `ExternalPlugin`.
///
/// Everything has a default, so a plugin implements only what it uses.
protocol HopPlugin: AnyObject {
    var info: PluginInfo { get }
    /// Sections of the plugin's Settings page. Field paths are full config key paths
    /// ("notes.folder"); a field marked `hidden` lives only in the config file.
    var settings: [SettingsSection] { get }

    /// Once, at launch, before the first `apply`.
    func start(_ host: PluginHost)
    /// The config was loaded or changed; `previous` is nil the first time. Called while the
    /// plugin is off too (with `enabled` false) so it can stop its work.
    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool)
    /// hop is quitting: save state.
    func stop()

    /// Root search commands (only asked while enabled).
    func commands() -> [Item]
    func prefixModes() -> [PrefixMode]
    func hotkeys(_ config: HopConfig) -> [PluginHotkey]
    func bindings() -> [PluginBinding]

    /// Items for the root's "Upcoming" section (empty query).
    func upcomingItems() -> [Item]
    /// An inline answer for a root query ("2+2", "5 usd"): a section shown above the results.
    /// `isAmbiguous`: the query also starts an app or command name, so loose answers should
    /// stay out of the way.
    func answer(for query: String, isAmbiguous: Bool) -> ResultSection?
    /// The mode a path query (`~/…`, `/…`) opens.
    func pathMode() -> Mode?
    /// Extra actions on an application row.
    func appActions(_ entry: AppEntry) -> [Action]

    func launcherWillShow()
    func setAway(_ away: Bool)
    /// The theme changed: `saved` false while the Theme picker previews one (only views
    /// attached to the launcher follow), true once it is saved (rebuild windows too).
    func themeDidChange(saved: Bool)
}

extension HopPlugin {
    var settings: [SettingsSection] { [] }
    func start(_ host: PluginHost) {}
    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {}
    func stop() {}
    func commands() -> [Item] { [] }
    func prefixModes() -> [PrefixMode] { [] }
    func hotkeys(_ config: HopConfig) -> [PluginHotkey] { [] }
    func bindings() -> [PluginBinding] { [] }
    func upcomingItems() -> [Item] { [] }
    func answer(for query: String, isAmbiguous: Bool) -> ResultSection? { nil }
    func pathMode() -> Mode? { nil }
    func appActions(_ entry: AppEntry) -> [Action] { [] }
    func launcherWillShow() {}
    func setAway(_ away: Bool) {}
    func themeDidChange(saved: Bool) {}
}

/// A plugin compiled into hop: its info and settings are known without an instance, so
/// Settings, the config check and tests can read them.
protocol BuiltinPlugin: HopPlugin {
    static var info: PluginInfo { get }
    static var settings: [SettingsSection] { get }
    init()
}

extension BuiltinPlugin {
    static var settings: [SettingsSection] { [] }
    var info: PluginInfo { Self.info }
    var settings: [SettingsSection] { Self.settings }
}

extension PluginInfo {
    /// Whether the plugin is on in `config`.
    func isEnabled(in config: HopConfig) -> Bool {
        if let enabledPath {
            return SettingsValue.read(enabledPath, in: config) as? Bool ?? enabledByDefault
        }
        return !config.plugins.disabled.contains(id)
    }

    /// Turns the plugin on or off in the config file: its own `enabled` key, or
    /// `plugins.disabled`. False when the file can't be written.
    @discardableResult
    func setEnabled(_ on: Bool, in settings: AppSettings) -> Bool {
        if let enabledPath { return settings.update(enabledPath, to: ConfigEdit.literal(on)) }
        var disabled = settings.data.plugins.disabled.filter { $0 != id }
        if !on { disabled.append(id) }
        return settings.update(["plugins", "disabled"], to: ConfigEdit.literal(disabled))
    }

    /// The plugin's page in the Settings window.
    func page(_ sections: [SettingsSection]) -> SettingsPage {
        // Without an `enabled` key of its own, the page starts with a switch for `plugins.disabled`.
        let all = enabledPath == nil ? [SettingsSection([.pluginEnabled])] + sections : sections
        return SettingsPage(id: id, title: name, subtitle: summary, symbol: symbol, color: color,
                            gate: enabledPath, sections: all, plugin: self)
    }
}

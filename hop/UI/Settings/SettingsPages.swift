import AppKit

/// One editable config key in the Settings window. `path` is the key path in
/// `config.json5`; the value shown is read from the loaded `HopConfig` at that path.
struct SettingsField {
    enum Kind {
        case toggle
        case text(placeholder: String = "")
        /// Hotkey syntax ("cmd+space"); `optional` allows "" (off).
        case hotkey(optional: Bool)
        case number(min: Int, max: Int, unit: String = "")
        case choice([(value: String, label: String)])
        /// Comma-separated in the field, a JSON array in the file.
        case list(placeholder: String = "")
        case multiline
        /// A password field kept in the login Keychain (service, account), never in the config.
        case secret(service: String, account: String)
    }

    let path: [String]
    let label: String
    var help: String?
    let kind: Kind
    /// Only in the config file: the page lists it under "More in the config" instead of
    /// showing a control (rarely changed or advanced keys).
    var hidden = false

    /// Shown when the config has no value at `path` (an installed plugin's default).
    var fallback: Any?
    /// Checks the value as it is typed (`SettingsChecks`); an error is not saved.
    var check: SettingsCheck?

    init(_ path: String, _ label: String, _ kind: Kind, help: String? = nil, hidden: Bool = false, check: SettingsCheck? = nil) {
        self.init(path: path.split(separator: ".").map(String.init), label, kind, help: help, hidden: hidden, check: check)
    }

    /// A key path whose keys may contain dots (`["plugins", "dev.you.plugin", "token"]`).
    init(path: [String], _ label: String, _ kind: Kind, help: String? = nil, hidden: Bool = false, fallback: Any? = nil,
         check: SettingsCheck? = nil) {
        self.path = path
        self.label = label
        self.help = help
        self.kind = kind
        self.hidden = hidden
        self.fallback = fallback
        self.check = check
    }

    var key: String { path.joined(separator: ".") }
}

/// A row that is not a config value: a summary with a button, or a plain button.
struct SettingsInfo {
    let label: String
    var help: String?
    /// Read-only lines under the label (e.g. the configured hotkeys).
    var lines: (HopConfig) -> [String] = { _ in [] }
    let button: String
    let action: SettingsAction
}

enum SettingsAction: Equatable {
    case openConfig, revealConfig, permissions, restart, checkForUpdates
    case open(String)
    case copy(String)
    /// Go to another Settings page by id.
    case showPage(String)
    /// Install a plugin from a GitHub link.
    case installPlugin(String)
    /// Remove an installed plugin by id.
    case removePlugin(String)
}

enum SettingsRow {
    case field(SettingsField)
    case info(SettingsInfo)
    /// Every plugin with its switch and a link to its page (the Plugins page).
    case plugins
    /// A GitHub link field and an Install button.
    case installPlugin
    /// The switch of a plugin that has no `enabled` key of its own (`plugins.disabled`).
    case pluginEnabled

    /// A config value with a control: `.setting("notes.folder", "Folder", .text())`.
    static func setting(_ path: String, _ label: String, _ kind: SettingsField.Kind, _ help: String? = nil,
                        hidden: Bool = false, check: SettingsCheck? = nil) -> SettingsRow {
        .field(SettingsField(path, label, kind, help: help, hidden: hidden, check: check))
    }
}

extension SettingsField.Kind {
    /// A pop-up of values shown capitalised.
    static func choices(_ values: [String]) -> Self {
        .choice(values.map { (value: $0, label: $0.prefix(1).uppercased() + $0.dropFirst()) })
    }
}

struct SettingsSection {
    var title: String?
    var rows: [SettingsRow]
    /// The About page's footer (`AuthorFooter`) instead of a card.
    var footer = false

    init(_ title: String, _ rows: [SettingsRow]) {
        self.title = title
        self.rows = rows
    }

    init(_ rows: [SettingsRow]) {
        title = nil
        self.rows = rows
    }

    static var authorFooter: SettingsSection {
        var s = SettingsSection([])
        s.footer = true
        return s
    }
}

struct SettingsPage {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let color: NSColor
    /// The page's `enabled` key: off greys out the rest of the page.
    var gate: [String]?
    let sections: [SettingsSection]
    /// The plugin the page belongs to.
    var plugin: PluginInfo?

    var fields: [SettingsField] {
        sections.flatMap(\.rows).compactMap { if case .field(let f) = $0 { f } else { nil } }
    }

    /// Search text: the page, its labels, help and keys.
    var haystack: String {
        var words = [title, subtitle]
        if sections.contains(where: \.footer) { words += ["pseudobun", "github", "website", "email"] }
        if let plugin { words += [plugin.tier.label, plugin.author ?? ""] + plugin.keywords }
        for row in sections.flatMap(\.rows) {
            switch row {
            case .field(let f): words += [f.label, f.help ?? "", f.key]
            case .info(let i): words += [i.label, i.help ?? ""]
            case .plugins, .installPlugin: words += ["plugins", "install", "github", "extensions"]
            case .pluginEnabled: words += ["enabled", "on", "off"]
            }
        }
        return words.joined(separator: " ").lowercased()
    }
}

struct SettingsGroup {
    let title: String
    let pages: [SettingsPage]
}

// MARK: - Reading values

nonisolated enum SettingsValue {
    /// The value at a key path of the config (property names are the JSON keys).
    static func read(_ path: [String], in config: HopConfig) -> Any? {
        guard let first = path.first else { return nil }
        // A plugin's section, or an installed plugin's settings (`plugins.<id>.<key>`).
        if let section = config.sections.section(first) { return read(path.dropFirst(), in: section.reflected) }
        if first == "plugins", path.count >= 3, path[1] != "disabled", path[1] != "install" {
            var value = config.plugins.settings[path[1]]
            for key in path.dropFirst(2) { value = value?[key] }
            return value?.plain
        }
        return read(path[...], in: config)
    }

    static func read(_ path: ArraySlice<String>, in root: Any) -> Any? {
        var value: Any = root
        for key in path {
            guard let child = Mirror(reflecting: value).children.first(where: { $0.label == key }) else { return nil }
            value = child.value
        }
        if let raw = value as? any RawRepresentable { return raw.rawValue }
        return value
    }
}

// MARK: - The pages

enum SettingsCatalog {
    private static func f(_ path: String, _ label: String, _ kind: SettingsField.Kind, _ help: String? = nil,
                          check: SettingsCheck? = nil) -> SettingsRow {
        .setting(path, label, kind, help, check: check)
    }

    private static func choices(_ values: [String]) -> SettingsField.Kind { .choices(values) }

    /// hop's own pages, then one Plugins group: the list, then each plugin's page A→Z, then Advanced.
    static func groups(plugins: [SettingsPage]) -> [SettingsGroup] {
        let pluginPages = plugins.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return [
            SettingsGroup(title: "hop", pages: [general, appearance, hotkeys]),
            SettingsGroup(title: "Plugins", pages: [pluginsPage] + pluginPages),
            SettingsGroup(title: "Advanced", pages: [configFile, about]),
        ]
    }

    /// The built-in plugins' pages, without running hop (tests, the config check).
    static var builtinPluginPages: [SettingsPage] {
        BuiltinPlugins.types.map { $0.info.page($0.settings) }
    }

    static var groups: [SettingsGroup] { groups(plugins: builtinPluginPages) }
    static var pages: [SettingsPage] { groups.flatMap(\.pages) }

    static var pluginsPage: SettingsPage {
        SettingsPage(id: "plugins", title: "Plugins", subtitle: "Turn plugins on or off, open their settings, install more.",
                     symbol: "puzzlepiece.extension.fill", color: Theme.info, sections: [
            SettingsSection([.plugins]),
            SettingsSection("Install from GitHub", [.installPlugin]),
        ])
    }

    static var general: SettingsPage {
        SettingsPage(id: "general", title: "General", subtitle: "The launcher hotkey, search and startup.",
                     symbol: "gearshape.fill", color: Palette.neutral, sections: [
            SettingsSection("Launcher", [
                f("general.hotkey", "Hotkey", .hotkey(optional: false), "Opens hop from anywhere."),
                f("general.sensitivity", "Search sensitivity", choices(Sensitivity.choices), "How loosely search matches."),
                f("general.popToRootSeconds", "Back to root after", .number(min: 0, max: 86_400, unit: "s"),
                  "Reopening after this long starts at the root search."),
                f("general.keepQueryFor", "Keep last search for", .number(min: 0, max: 86_400, unit: "s"),
                  "Reopening within this long brings back the last search, selected; 0 always starts empty."),
                f("general.fallbacks", "Fallbacks", .list(placeholder: "chatgpt, google, github"),
                  "Under root results and alone when nothing matches: chatgpt, google, github or a URL with {query}.",
                  check: SettingsChecks.fallbacks),
            ]),
            SettingsSection("Startup", [
                f("general.openAtLogin", "Open at login", .toggle),
                f("general.menuBarIcon", "Menu bar icon", .toggle, "The bunny in the menu bar: Open, Notes, Clipboard, Settings."),
            ]),
            SettingsSection("Updates", [
                f("updates.check", "Check for updates", .toggle,
                  "Once a day, downloaded in the background; installs when hop quits, or from the launcher or hop update."),
                f("updates.automatic", "Install right away", .toggle, "As soon as it is downloaded; hop restarts."),
                f("updates.channel", "Channel", .choice([("auto", "Automatic"), ("beta", "Beta"), ("stable", "Stable")]),
                  "Automatic follows the hop you run (now \(AppPaths.version)); Beta also gets betas. There is no stable version yet. \"Update Channel\" in the launcher picks it too."),
                .info(SettingsInfo(label: "Latest release", lines: { _ in
                    guard Updater.shared.isAvailable else { return ["Builds from source don't check"] }
                    return [Updater.shared.pending.map { "hop \($0) is downloaded and ready" } ?? Updater.shared.state.text]
                }, button: "Update Now", action: .checkForUpdates)),
            ]),
        ])
    }

    static var appearance: SettingsPage {
        let themes = Theme.all.map { (value: $0.rawValue, label: $0.isBuiltIn ? Theme.spec($0).label : "\(Theme.spec($0).label) (custom)") }
        return SettingsPage(id: "appearance", title: "Appearance", subtitle: "Colours and fonts for every hop window.",
                            symbol: "paintpalette.fill", color: Theme.chart5, sections: [
            SettingsSection([
                f("general.theme", "Theme", .choice(themes),
                  "Applies at once. The Theme command in the launcher previews each one live. Your own themes are .json5 files in ~/.config/hop/themes/; the Theme command can start or import one."),
                f("general.glass", "Liquid Glass", .toggle,
                  "The wallpaper shows through the launcher, clipboard, notes and HUD, tinted with the theme. Off: the flat, mostly opaque look."),
                f("general.glassStyle", "Glass", .choice([("regular", "Regular"), ("clear", "Clear")]),
                  "Regular is frosted like Spotlight; Clear is barely frosted and shows the most of what is behind."),
                f("general.glassTint", "Tint", .number(min: 0, max: 100, unit: "%"),
                  "How much of the theme's background colours the glass. 0 is bare glass; 100 is close to the flat look. Notes keep a little more for long text."),
            ]),
        ])
    }

    static var hotkeys: SettingsPage {
        SettingsPage(id: "hotkeys", title: "Hotkeys", subtitle: "Global hotkeys for any command or app.",
                     symbol: "command", color: Theme.info, sections: [
            SettingsSection([
                .info(SettingsInfo(
                    label: "Bindings",
                    help: "Key: a command title (\"Empty Trash\"), an app name (\"Safari\"), a command id or \"app:\" + bundle id. `hop hotkeys` lists them.",
                    lines: { config in
                        config.hotkeys.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                            .map { "\($0.key)  →  \(HotkeySpec.display($0.value))" }
                    },
                    button: "Edit in Config", action: .openConfig)),
            ]),
        ])
    }

















    static var configFile: SettingsPage {
        SettingsPage(id: "config", title: "Config File", subtitle: "Everything here is saved to config.json5, comments kept.",
                     symbol: "doc.text.fill", color: Palette.neutral, sections: [
            SettingsSection([
                .info(SettingsInfo(label: "Open in editor", help: "Changes saved there apply at once, here too.",
                                   button: "Open Config", action: .openConfig)),
                .info(SettingsInfo(label: "Show in Finder", button: "Reveal", action: .revealConfig)),
            ]),
            SettingsSection("hop", [
                .info(SettingsInfo(label: "Permissions", help: "Accessibility, Finder, Downloads, Open at Login.",
                                   button: "Show", action: .permissions)),
                .info(SettingsInfo(label: "Restart hop", button: "Restart", action: .restart)),
            ]),
        ])
    }

    static var about: SettingsPage {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return SettingsPage(id: "about", title: "About", subtitle: "A launcher for macOS, by pseudobun.",
                            symbol: "hare.fill", color: Palette.neutral, sections: [
            SettingsSection("hop", [
                .info(SettingsInfo(label: "Version", help: "\(version) (build \(build))", button: "Copy",
                                   action: .copy("\(version) (\(build))"))),
                .info(SettingsInfo(label: "Source code", help: "github.com/pseudobun/hop", button: "Open",
                                   action: .open("https://github.com/pseudobun/hop"))),
            ]),
            .authorFooter,
        ])
    }
}

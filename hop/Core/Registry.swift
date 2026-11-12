import AppKit

/// Shared services handed to commands and modes. A plugin's own objects are reached through
/// `plugin(_:)` (each plugin adds a shortcut, e.g. `services.notes`).
final class Services {
    let settings: AppSettings
    let frecency: FrecencyStore
    let apps: AppIndex
    weak var plugins: PluginManager?
    var permissionsMode: (() -> Mode)?
    /// Shows the app in a theme without saving it (the Theme picker's preview).
    var previewTheme: ((HopConfig.General.ThemeName) -> Void)?
    /// Reads the custom themes again now, e.g. right after one was created or imported.
    var reloadThemes: (() -> Void)?
    /// Opens the Settings window, on a page (`SettingsPage.id`) or the last one.
    var openSettings: ((String?) -> Void)?
    /// Hides the launcher, e.g. before pasting into the app behind it.
    var hideLauncher: (() -> Void)?
    /// Opens the config file in the user's editor, at the parse error when there is one.
    func openConfig() {
        ConfigOpener.open(settings.url, at: settings.error)
    }

    func plugin<P: HopPlugin>(_ type: P.Type) -> P? { plugins?.plugin(type) }

    init(settings: AppSettings, frecency: FrecencyStore, apps: AppIndex) {
        self.settings = settings
        self.frecency = frecency
        self.apps = apps
    }
}

/// Root commands: hop's own, then those of the plugins that are on.
enum Registry {
    static func commands(_ services: Services) -> [Item] {
        var items: [Item] = []
        items += ThemeCommands.items(services)
        items += OpenAICommands.items(services)
        items += UpdateCommands.items(services)
        items += services.plugins?.commands() ?? []
        items += [
            Item(id: "hop.settings", title: "Settings", subtitle: "hop's preferences",
                 aliases: ["preferences", "config", "configure", "options", "hop settings"],
                 icon: .tile("gearshape.2.fill", Theme.info), accessory: "⌘,",
                 actions: [
                     Action(title: "Open Settings", symbol: "gearshape.2") {
                         services.openSettings?(nil)
                         return .stay
                     },
                     Action(title: "Open Config File", shortcut: .ret(.command)) {
                         services.openConfig()
                         return .dismiss
                     },
                 ]),
            Item(id: "hop.plugins", title: "Open Plugins", subtitle: "Turn plugins on or off, install more from GitHub",
                 aliases: ["plugins", "extensions", "install plugin", "hop plugins"],
                 icon: .tile("puzzlepiece.extension.fill", Theme.info), accessory: "Command",
                 actions: [
                     Action(title: "Open Plugins", symbol: "puzzlepiece.extension") {
                         services.openSettings?("plugins")
                         return .stay
                     },
                 ]),
            Item(id: "hop.config", title: "Open hop Config", subtitle: "~/.config/hop/config.json5",
                 icon: .tile("gearshape.fill", Palette.neutral), accessory: "Command",
                 actions: [
                     Action(title: "Open Config") {
                         services.openConfig()
                         return .dismiss
                     },
                     Action(title: "Show in Finder", shortcut: .ret(.command)) {
                         NSWorkspace.shared.activateFileViewerSelecting([services.settings.url])
                         return .dismiss
                     },
                 ]),
            Item(id: "hop.permissions", title: "hop Permissions", subtitle: "Accessibility, Finder, Downloads, Open at Login",
                 icon: .tile("checkmark.shield.fill", Theme.info), accessory: "Command",
                 actions: [Action(title: "Show Permissions") { .push(services.permissionsMode?() ?? PermissionsMode { services.settings.data }) }],
                 pushesMode: true),
            Item(id: "hop.restart", title: "Restart hop", icon: .tile("arrow.clockwise", Theme.info), accessory: "Command",
                 actions: [HopApp.restartAction()], tracksFrecency: false),
            Item(id: "hop.quit", title: "Quit hop", icon: .tile("power", Theme.chart5), accessory: "Command",
                 actions: [HopApp.quitAction()], tracksFrecency: false),
        ]
        let bindings = services.settings.data.hotkeys
        if !bindings.isEmpty {
            items = items.map { item in
                var item = item
                if let h = HotkeyLookup.binding(id: item.id, title: item.title, in: bindings) { item.accessory = HotkeySpec.display(h) }
                return item
            }
        }
        return items
    }
}

/// Quitting and restarting hop itself.
enum HopApp {
    static func restartAction() -> Action {
        Action(title: "Restart hop") { restart() ? .dismiss : .failWithHUD("Could not restart hop") }
    }

    static func quitAction(shortcut: KeyCombo? = nil) -> Action {
        Action(title: "Quit hop", shortcut: shortcut) {
            NSApp.terminate(nil)
            return .dismiss
        }
    }

    /// Opens a fresh copy once this process has exited, so the old one's cleanup
    /// (restoring the Caps Lock mapping) can't undo the new one's setup, then quits.
    static func restart() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath]
        do { try p.run() } catch { return false }
        NSApp.terminate(nil)
        return true
    }
}


extension ActionResult {
    /// The HUD an action's result asks for, when it ran without the launcher (a hotkey).
    func showHUD() {
        switch self {
        case .dismissWithHUD(let text), .stayWithHUD(let text): HUD.shared.show(text)
        case .failWithHUD(let text): HUD.shared.fail(text)
        case .warnWithHUD(let text): HUD.shared.warn(text)
        case .dismiss, .stay, .pop, .reload, .push: break
        }
    }
}

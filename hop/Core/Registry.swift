import AppKit

/// Shared services handed to commands and modes.
final class Services {
    let settings: AppSettings
    let frecency: FrecencyStore
    let apps: AppIndex
    var hyper: HyperKeyController?
    var keepassMode: (() -> Mode)?
    var keepass: KeePassManager?
    var permissionsMode: (() -> Mode)?
    var notes: NotesController?
    var clipboard: ClipboardController?
    var snippets: SnippetService?
    var shelves: ShelfController?
    var calendar: CalendarController?
    /// Hides the launcher, e.g. before pasting into the app behind it.
    var hideLauncher: (() -> Void)?
    /// Opens the config file in the user's editor, at the parse error when there is one.
    func openConfig() {
        ConfigOpener.open(settings.url, at: settings.error)
    }

    init(settings: AppSettings, frecency: FrecencyStore, apps: AppIndex) {
        self.settings = settings
        self.frecency = frecency
        self.apps = apps
    }
}

/// Compiled-in root commands. One feature adds its items here.
enum Registry {
    static func commands(_ services: Services) -> [Item] {
        var items: [Item] = []
        items += SystemCommands.items(services)
        items += WireGuardCommands.items(services)
        items += KeePassCommands.items(services)
        items += BookmarkCommands.items(services)
        items += NotesCommands.items(services)
        items += ClipboardCommands.items(services)
        items += SnippetCommands.items(services)
        items += FileCommands.items(services)
        items += ShelfCommands.items(services)
        items += MessagesCommands.items(services)
        items += CalendarCommands.items(services)
        items += CalculatorCommands.items(services)
        items += [
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
                if let h = HotkeyLookup.binding(id: item.id, title: item.title, in: bindings) { item.accessory = NotesCommands.display(h) }
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


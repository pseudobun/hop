import AppKit

/// Shared services handed to commands and modes.
final class Services {
    let settings: AppSettings
    let frecency: FrecencyStore
    let apps: AppIndex
    var hyper: HyperKeyController?
    /// Opens the config file in the user's editor.
    func openConfig() {
        let url = settings.url
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
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
        items += [
            Item(id: "hop.config", title: "Open hop Config", subtitle: "~/.config/hop/config.json5",
                 icon: .symbol("gearshape"), accessory: "Command",
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
            Item(id: "hop.quit", title: "Quit hop", icon: .symbol("power"), accessory: "Command",
                 actions: [Action(title: "Quit hop") {
                     NSApp.terminate(nil)
                     return .dismiss
                 }], tracksFrecency: false),
        ]
        return items
    }
}


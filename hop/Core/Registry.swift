import AppKit
import SwiftUI

/// Shared services handed to commands and modes.
final class Services {
    let settings: AppSettings
    let frecency: FrecencyStore
    let apps: AppIndex
    var openSettings: () -> Void = {}

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
        items += [
            Item(id: "hop.settings", title: "hop Settings", icon: .symbol("gearshape"), accessory: "Command",
                 actions: [Action(title: "Open Settings") {
                     services.openSettings()
                     return .dismiss
                 }]),
            Item(id: "hop.quit", title: "Quit hop", icon: .symbol("power"), accessory: "Command",
                 actions: [Action(title: "Quit hop") {
                     NSApp.terminate(nil)
                     return .dismiss
                 }], tracksFrecency: false),
        ]
        return items
    }
}

/// Feature sections appended to the Settings window.
struct SettingsSections: View {
    @Bindable var settings: AppSettings

    var body: some View {
        EmptyView()
    }
}

/// System commands; filled in by the System feature.
enum SystemCommands {
    static func items(_ services: Services) -> [Item] { [] }
}

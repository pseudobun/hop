import AppKit

/// Root command for the clipboard history window.
enum ClipboardCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.clipboard
        guard config.enabled, let clipboard = services.clipboard else { return [] }
        let hotkey = HotkeySpec.parse(config.hotkey).map { _ in HotkeySpec.display(config.hotkey) }
        return [
            Item(id: "clipboard.history", title: "Clipboard History", subtitle: "Text, images, links, colours and files you copied",
                 icon: .tile("doc.on.clipboard.fill", Palette.clipboard), accessory: hotkey ?? "Command",
                 actions: [Action(title: "Open Clipboard History", symbol: "doc.on.clipboard") {
                     clipboard.show()
                     return .dismiss
                 }]),
        ]
    }
}

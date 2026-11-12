import AppKit

/// Root commands for shelves.
enum ShelfCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.shelf
        guard config.enabled, let shelves = services.shelves else { return [] }
        let key = { (spec: String) in HotkeySpec.parse(spec).map { _ in HotkeySpec.display(spec) } ?? "Command" }
        var items = [
            Item(id: "shelf.new", title: "New Shelf", subtitle: activation(config),
                 aliases: ["dropover", "drop"], icon: .tile("tray.fill", Palette.shelf), accessory: key(config.hotkey),
                 actions: [Action(title: "New Shelf", symbol: "tray") {
                     shelves.newShelf()
                     return .dismiss
                 }]),
            Item(id: "shelf.clipboard", title: "New Shelf from Clipboard", subtitle: "Files, links, images or text you copied",
                 icon: .tile("doc.on.clipboard.fill", Palette.shelf), accessory: key(config.clipboardHotkey),
                 actions: [Action(title: "New Shelf from Clipboard", symbol: "doc.on.clipboard") {
                     shelves.newShelfFromClipboard()
                     return .dismiss
                 }]),
        ]
        if let last = shelves.recent.first {
            items.append(Item(id: "shelf.reopen", title: "Reopen Shelf", subtitle: ShelfStackTile.summary(last),
                              icon: .tile("arrow.uturn.backward", Palette.shelf), accessory: key(config.reopenHotkey),
                              actions: [Action(title: "Reopen Shelf", symbol: "arrow.uturn.backward") {
                                  shelves.reopenLast()
                                  return .dismiss
                              }]))
        }
        if !shelves.shelves.isEmpty {
            items.append(Item(id: "shelf.closeAll", title: "Close All Shelves", subtitle: "\(shelves.shelves.count) open",
                              icon: .tile("xmark", Palette.shelf), accessory: "Command",
                              actions: [Action(title: "Close All Shelves", symbol: "xmark") {
                                  shelves.closeAll()
                                  return .dismiss
                              }], tracksFrecency: false))
        }
        return items
    }

    /// How a shelf opens while dragging, for the command's subtitle.
    private static func activation(_ config: HopConfig.Shelf) -> String {
        var ways: [String] = []
        if config.shake { ways.append("shake while dragging") }
        if let mods = DragWatcher.modifiers(config.modifier), !mods.isEmpty {
            ways.append("hold \(HotkeySpec.display(config.modifier)) while dragging")
        }
        return ways.isEmpty ? "A floating shelf to park files, links and text" : "Or " + ways.joined(separator: ", ")
    }
}

import AppKit

/// Root commands for the notes window.
enum NotesCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.notes
        guard config.enabled, let notes = services.notes else { return [] }
        let folder = (config.expandedFolder as NSString).lastPathComponent
        let hotkey = HotkeySpec.parse(config.hotkey).map { _ in Self.display(config.hotkey) }
        return [
            Item(id: "notes.open", title: "Notes", subtitle: "Markdown notes in \(folder)",
                 icon: .tile("note.text", Palette.notes), accessory: hotkey ?? "Command",
                 actions: [Action(title: "Open Notes", symbol: "note.text") {
                     notes.show()
                     return .dismiss
                 }]),
            Item(id: "notes.new", title: "New Note", subtitle: "In \(config.newNoteFolder.isEmpty ? folder : config.newNoteFolder)",
                 icon: .tile("square.and.pencil", Palette.notes), accessory: "Command",
                 actions: [Action(title: "Create Note", symbol: "square.and.pencil") {
                     notes.show(newNote: true)
                     return .dismiss
                 }]),
        ]
    }

    static func display(_ spec: String) -> String { HotkeySpec.display(spec) }
}

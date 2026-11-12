import AppKit

/// Notes: a floating window over a folder of Markdown files.
final class NotesPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "notes", name: "Notes", summary: "A floating window over a folder of Markdown files.", symbol: "note.text",
                   color: Palette.notes, category: .tools, enabledPath: ["notes", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("notes.enabled", "Notes", .toggle),
                .setting("notes.hotkey", "Hotkey", .hotkey(optional: false), "Opens the notes window from anywhere."),
                .setting("notes.folder", "Folder", .text(placeholder: "~/Notes"), "Folder of Markdown files; an Obsidian vault works as is.", check: SettingsChecks.folder()),
                .setting("notes.newNoteFolder", "New notes go to", .text(placeholder: "Inbox"), "Relative to the folder.", check: SettingsChecks.relativeFolder),
                .setting("notes.bumpUpdated", "Bump `updated:`", .toggle, "Set an existing `updated:` date in the frontmatter to today when you edit a note."),
            ]),
            SettingsSection("Template", [
                .setting("notes.template", "New note", .multiline, "{{title}} and {{date}} are filled in."),
            ]),
        ]
    }

    init() {}

    private(set) var controller: NotesController!
    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        makeController()
    }

    private func makeController() {
        guard let host else { return }
        controller = NotesController(settings: host.settings)
        controller.openConfig = { [weak host] in host?.openConfig() }
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        if !config.notes.enabled { controller.hide() }
        if previous != nil && previous?.notes.folder != config.notes.folder { controller.folderChanged() }
    }

    func commands() -> [Item] { NotesCommands.items(host!.services) }

    func hotkeys(_ config: HopConfig) -> [PluginHotkey] {
        [PluginHotkey(owner: "the notes hotkey", spec: config.notes.hotkey) { [weak self] in
            self?.host?.launcher.hide()
            self?.controller.toggle()
        }]
    }

    func bindings() -> [PluginBinding] {
        [
            PluginBinding(names: ["notes.open", "notes"]) { [weak self] in self?.controller.toggle() },
            PluginBinding(names: ["notes.new", "new note"]) { [weak self] in
                self?.host?.launcher.hide()
                self?.controller.show(newNote: true)
            },
        ]
    }

    func themeDidChange(saved: Bool) {
        guard saved else { return }
        let shown = controller.isVisible
        controller.hide()
        makeController()
        if shown { controller.show() }
    }

    func stop() { controller?.saveNow() }
}

extension Services {
    var notes: NotesController? { plugin(NotesPlugin.self)?.controller }
}

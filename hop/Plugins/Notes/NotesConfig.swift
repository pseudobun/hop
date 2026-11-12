import Foundation

nonisolated extension HopConfig {
    nonisolated struct Notes: PluginConfig {
        static let key = "notes"
        var enabled = true
        var hotkey = "alt+."
        /// Folder of Markdown files; an Obsidian vault works as is.
        var folder = "~/Notes"
        /// Where new notes go, relative to `folder`.
        var newNoteFolder = "Inbox"
        /// Start of every new note; `{{title}}` and `{{date}}` are filled in.
        var template = "---\ntitle: {{title}}\ntags: [inbox]\ntype: note\nstatus: stub\nupdated: {{date}}\n---\n\n"
        /// Set an existing `updated:` frontmatter date to today when a note is edited.
        var bumpUpdated = true

        var expandedFolder: String { folder.expandingTilde }
    }

    var notes: Notes {
        get { sections[Notes.self] }
        set { sections[Notes.self] = newValue }
    }
}

nonisolated extension HopConfig.Notes {
    private enum Keys: String, CodingKey { case enabled, hotkey, folder, newNoteFolder, template, bumpUpdated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        hotkey = try c.value(.hotkey, d.hotkey)
        folder = try c.value(.folder, d.folder)
        newNoteFolder = try c.value(.newNoteFolder, d.newNoteFolder)
        template = try c.value(.template, d.template)
        bumpUpdated = try c.value(.bumpUpdated, d.bumpUpdated)
    }
}

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
    }

    let path: [String]
    let label: String
    var help: String?
    let kind: Kind

    init(_ path: String, _ label: String, _ kind: Kind, help: String? = nil) {
        self.path = path.split(separator: ".").map(String.init)
        self.label = label
        self.help = help
        self.kind = kind
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
}

enum SettingsRow {
    case field(SettingsField)
    case info(SettingsInfo)
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

    var fields: [SettingsField] {
        sections.flatMap(\.rows).compactMap { if case .field(let f) = $0 { f } else { nil } }
    }

    /// Search text: the page, its labels, help and keys.
    var haystack: String {
        var words = [title, subtitle]
        if sections.contains(where: \.footer) { words += ["pseudobun", "github", "website", "email"] }
        for row in sections.flatMap(\.rows) {
            switch row {
            case .field(let f): words += [f.label, f.help ?? "", f.key]
            case .info(let i): words += [i.label, i.help ?? ""]
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
        var value: Any = config
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
    private static func f(_ path: String, _ label: String, _ kind: SettingsField.Kind, _ help: String? = nil) -> SettingsRow {
        .field(SettingsField(path, label, kind, help: help))
    }

    private static func choices(_ values: [String]) -> SettingsField.Kind {
        .choice(values.map { (value: $0, label: $0.prefix(1).uppercased() + $0.dropFirst()) })
    }

    static var groups: [SettingsGroup] {
        [
            SettingsGroup(title: "hop", pages: [general, appearance, hotkeys]),
            SettingsGroup(title: "Keyboard", pages: [hyperKey, snippets]),
            SettingsGroup(title: "Tools", pages: [clipboard, notes, files, shelf, calculator]),
            SettingsGroup(title: "AI", pages: [emoji, translate, ocr]),
            SettingsGroup(title: "Integrations", pages: [wireguard, keepass, calendar, messages, bookmarks]),
            SettingsGroup(title: "Advanced", pages: [system, configFile, about]),
        ]
    }

    static var pages: [SettingsPage] { groups.flatMap(\.pages) }

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
                  "Under root results and alone when nothing matches: chatgpt, google, github or a URL with {query}."),
            ]),
            SettingsSection("Startup", [
                f("general.openAtLogin", "Open at login", .toggle),
                f("general.menuBarIcon", "Menu bar icon", .toggle, "The bunny in the menu bar: Open, Notes, Clipboard, Settings."),
            ]),
            SettingsSection("Updates", [
                f("updates.check", "Check for updates", .toggle,
                  "Once a day, from GitHub releases; brew upgrade --cask pseudobun/tap/hop installs one. Builds from source don't check."),
                .info(SettingsInfo(label: "Latest release", lines: { _ in
                    [Updater.shared.isAvailable ? Updater.shared.state.text : "Builds from source don't check"]
                }, button: "Check Now", action: .checkForUpdates)),
            ]),
        ])
    }

    static var appearance: SettingsPage {
        let themes = HopConfig.General.ThemeName.allCases.map { (value: $0.rawValue, label: Theme.spec($0).label) }
        return SettingsPage(id: "appearance", title: "Appearance", subtitle: "Colours and fonts for every hop window.",
                            symbol: "paintpalette.fill", color: Theme.chart5, sections: [
            SettingsSection([
                f("general.theme", "Theme", .choice(themes),
                  "Applies at once. The Theme command in the launcher previews each one live."),
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
                            .map { "\($0.key)  →  \(NotesCommands.display($0.value))" }
                    },
                    button: "Edit in Config", action: .openConfig)),
            ]),
        ])
    }

    static var hyperKey: SettingsPage {
        SettingsPage(id: "hyperKey", title: "Hyper Key", subtitle: "Caps Lock as ⌃⌥⌘⇧.",
                     symbol: "capslock.fill", color: Theme.chart3, gate: ["hyperKey", "enabled"], sections: [
            SettingsSection([
                f("hyperKey.enabled", "Caps Lock is Hyper", .toggle, "Needs Accessibility permission."),
                f("hyperKey.quickPressEscape", "Tap for Escape", .toggle, "Caps Lock pressed and released on its own sends Escape."),
            ]),
        ])
    }

    static var snippets: SettingsPage {
        SettingsPage(id: "snippets", title: "Snippets", subtitle: "Text you insert by name or by typing a keyword.",
                     symbol: "text.badge.plus", color: Palette.snippets, gate: ["snippets", "enabled"], sections: [
            SettingsSection([
                f("snippets.enabled", "Snippets", .toggle),
                f("snippets.expand", "Expand keywords", .toggle, "Type a snippet's keyword anywhere and it becomes the snippet (needs Accessibility)."),
                f("snippets.expandWithinWords", "Expand within words", .toggle, "Also expand keywords typed in the middle of a word."),
                f("snippets.disabledApps", "Never expand in", .list(placeholder: "com.apple.Terminal"), "Bundle identifiers, comma-separated."),
                f("snippets.file", "Snippets file", .text(placeholder: "~/.config/hop/snippets.json5"), "\"Edit Snippets\" in hop opens it."),
            ]),
        ])
    }

    static var clipboard: SettingsPage {
        SettingsPage(id: "clipboard", title: "Clipboard", subtitle: "History of what you copy.",
                     symbol: "doc.on.clipboard.fill", color: Palette.clipboard, gate: ["clipboard", "enabled"], sections: [
            SettingsSection([
                f("clipboard.enabled", "Clipboard history", .toggle),
                f("clipboard.hotkey", "Hotkey", .hotkey(optional: false), "Opens the history from anywhere."),
                f("clipboard.pasteOnReturn", "↵ pastes", .toggle, "Paste into the app you were in; off only copies."),
            ]),
            SettingsSection("Storage", [
                f("clipboard.keepDays", "Keep for", .number(min: -1, max: 36_500, unit: "days"), "Unpinned entries; -1 keeps them forever."),
                f("clipboard.maxItems", "At most", .number(min: 1, max: 100_000, unit: "items")),
                f("clipboard.images", "Keep images", .toggle),
                f("clipboard.maxImageMB", "Largest image", .number(min: 1, max: 1_000, unit: "MB")),
            ]),
            SettingsSection("Privacy", [
                f("clipboard.ignoreApps", "Never record from", .list(placeholder: "com.1password.1password"),
                  "Bundle identifiers. Copies marked concealed (KeePassXC, 1Password, hop) are skipped anyway."),
                f("clipboard.cliAccess", "Allow `hop clip`", .toggle, "Lets the CLI (and agents) read the history; it holds whatever you copied."),
            ]),
        ])
    }

    static var notes: SettingsPage {
        SettingsPage(id: "notes", title: "Notes", subtitle: "A floating window over a folder of Markdown files.",
                     symbol: "note.text", color: Palette.notes, gate: ["notes", "enabled"], sections: [
            SettingsSection([
                f("notes.enabled", "Notes", .toggle),
                f("notes.hotkey", "Hotkey", .hotkey(optional: false), "Opens the notes window from anywhere."),
                f("notes.folder", "Folder", .text(placeholder: "~/Notes"), "Folder of Markdown files; an Obsidian vault works as is."),
                f("notes.newNoteFolder", "New notes go to", .text(placeholder: "Inbox"), "Relative to the folder."),
                f("notes.bumpUpdated", "Bump `updated:`", .toggle, "Set an existing `updated:` date in the frontmatter to today when you edit a note."),
            ]),
            SettingsSection("Template", [
                f("notes.template", "New note", .multiline, "{{title}} and {{date}} are filled in."),
            ]),
        ])
    }

    static var files: SettingsPage {
        SettingsPage(id: "files", title: "Files", subtitle: "File search with Spotlight's index.",
                     symbol: "folder.fill", color: Palette.files, gate: ["files", "enabled"], sections: [
            SettingsSection([
                f("files.enabled", "File search", .toggle),
                f("files.scopes", "Search in", .list(placeholder: "~"), "Folders, comma-separated."),
                f("files.exclude", "Hide paths with", .list(placeholder: "node_modules, .git"), "Folder names anywhere in a result's path."),
                f("files.contentSearch", "Search file contents", .toggle, "Also find files by the text inside them."),
                f("files.maxResults", "At most", .number(min: 1, max: 1_000, unit: "results")),
                f("files.showHidden", "Show dotfiles", .toggle, "When browsing a path (~/…)."),
            ]),
        ])
    }

    static var shelf: SettingsPage {
        SettingsPage(id: "shelf", title: "Shelf", subtitle: "Park files, links, images and text while you drag.",
                     symbol: "tray.fill", color: Palette.shelf, gate: ["shelf", "enabled"], sections: [
            SettingsSection([
                f("shelf.enabled", "Shelves", .toggle),
                f("shelf.shake", "Shake to open", .toggle, "Shake the pointer while dragging to open a shelf under it."),
                f("shelf.shakeSensitivity", "Shake sensitivity", choices(ShakeDetector.Sensitivity.choices), "How small a shake counts."),
                f("shelf.modifier", "Hold while dragging", .text(placeholder: "shift"), "\"shift\", \"alt\", \"ctrl+alt\"; empty turns it off."),
                f("shelf.keepAfterDragOut", "Keep dragged-out items", .toggle),
                f("shelf.ignoreApps", "Never open for", .list(placeholder: "com.apple.finder"), "Drags from these apps (bundle identifiers)."),
            ]),
            SettingsSection("Hotkeys", [
                f("shelf.hotkey", "New shelf", .hotkey(optional: true)),
                f("shelf.clipboardHotkey", "New shelf from clipboard", .hotkey(optional: true)),
                f("shelf.reopenHotkey", "Reopen last shelf", .hotkey(optional: true)),
            ]),
        ])
    }

    static var calculator: SettingsPage {
        SettingsPage(id: "calculator", title: "Calculator", subtitle: "Inline answers: maths, units, currencies.",
                     symbol: "plus.forwardslash.minus", color: Theme.chart2, sections: [
            SettingsSection([
                f("calculator.currencies", "Currencies", .toggle,
                  "Rates from open.er-api.com, fetched only after you type a currency, at most twice a day."),
                f("calculator.currency", "Default currency", .text(placeholder: "EUR"), "Where an amount goes when you type no target (\"50 usd\")."),
            ]),
        ])
    }

    static var emoji: SettingsPage {
        SettingsPage(id: "emoji", title: "Emoji", subtitle: "Search Emoji, or type \":\" in hop.",
                     symbol: "face.smiling.inverse", color: Palette.emoji, gate: ["emoji", "enabled"], sections: [
            SettingsSection([
                f("emoji.enabled", "Emoji search", .toggle),
                f("emoji.skinTone", "Skin tone", .choice([
                    ("none", "None"), ("light", "Light"), ("mediumLight", "Medium light"), ("medium", "Medium"),
                    ("mediumDark", "Medium dark"), ("dark", "Dark"),
                ]), "For emoji that take one."),
            ]),
            SettingsSection("AI suggestions", [
                f("emoji.ai", "Ask OpenAI", .toggle, "For phrases the index can't place; only with a key (\"Set OpenAI API Key\")."),
                f("emoji.aiModel", "Model", .text(placeholder: "gpt-6-luna")),
                f("emoji.aiReasoning", "Reasoning effort", .text(placeholder: "none"), "\"none\" answers in about 1.5 s; empty leaves it out."),
            ]),
        ])
    }

    static var translate: SettingsPage {
        SettingsPage(id: "translate", title: "Translate", subtitle: "\"tr \" in hop: between two languages with OpenAI.",
                     symbol: "character.bubble.fill", color: Palette.translate, gate: ["translate", "enabled"], sections: [
            SettingsSection([
                f("translate.enabled", "Translate", .toggle),
                f("translate.languages", "Languages", .list(placeholder: "de, en"),
                  "Two ISO 639 codes: text in the first goes to the second, anything else to the first. Empty: your macOS language and English."),
                f("translate.model", "Model", .text(placeholder: "gpt-6.1-terra")),
                f("translate.reasoning", "Reasoning effort", .text(placeholder: "none"), "\"none\", \"low\", …; empty leaves it out."),
            ]),
        ])
    }

    static var ocr: SettingsPage {
        SettingsPage(id: "ocr", title: "Screen Text", subtitle: "Copy Text from Screen, read on this Mac.",
                     symbol: "text.viewfinder", color: Palette.ocr, gate: ["ocr", "enabled"], sections: [
            SettingsSection([
                f("ocr.enabled", "Copy Text from Screen", .toggle),
                f("ocr.languages", "Languages", .list(placeholder: "en-US, sl-SI"), "Vision recognition languages, most likely first."),
            ]),
        ])
    }

    static var wireguard: SettingsPage {
        SettingsPage(id: "wireguard", title: "WireGuard", subtitle: "Tunnels in the launcher and in the bar under it.",
                     symbol: "network.badge.shield.half.filled", color: Palette.wireguard, gate: ["wireguard", "enabled"], sections: [
            SettingsSection([
                f("wireguard.enabled", "WireGuard", .toggle),
                f("wireguard.showFlags", "Flags", .toggle, "From a tunnel name prefix: \"si-home\" → 🇸🇮."),
                f("wireguard.exclusive", "One tunnel at a time", .toggle, "Activating a tunnel deactivates the others first."),
            ]),
            SettingsSection("Bar", [
                f("wireguard.bar", "Tunnel bar", .toggle, "Tunnels as pills under the search field; click one to toggle it."),
                f("wireguard.barTunnels", "Tunnels in the bar", .list(placeholder: "all"), "Names in order; empty shows every tunnel."),
                f("wireguard.keys.focus", "Select in the bar", .hotkey(optional: true), "In the launcher: ←→ move, ↵ toggles, Esc goes back."),
                f("wireguard.keys.disconnectAll", "Disconnect all", .hotkey(optional: true)),
                f("wireguard.keys.direct", "Toggle with 1…9", .text(placeholder: "alt+cmd"), "Modifiers for 1…9 that toggle a tunnel at once; empty is off."),
            ]),
        ])
    }

    static var keepass: SettingsPage {
        SettingsPage(id: "keepass", title: "KeePassXC", subtitle: "Search and copy passwords from .kdbx databases.",
                     symbol: "key.fill", color: Palette.keepass, gate: ["keepass", "enabled"], sections: [
            SettingsSection([
                f("keepass.enabled", "KeePassXC", .toggle),
                .info(SettingsInfo(
                    label: "Databases",
                    help: "Paths, key files and where each master password comes from live in the config.",
                    lines: { config in
                        config.keepass.allDatabases.map { "\($0.label)  ·  \($0.path)  ·  \($0.password.rawValue)" }
                    },
                    button: "Edit in Config", action: .openConfig)),
                f("keepass.favicons", "Site icons", .toggle, "Fetched straight from each entry's website and cached."),
            ]),
            SettingsSection("Locking", [
                f("keepass.autoLock", "Lock automatically", .toggle,
                  "On sleep, screen lock and after the minutes below. Off: a database stays open until ⌘L or quitting hop."),
                f("keepass.lockAfterMinutes", "Lock after", .number(min: -1, max: 1_440, unit: "min"), "-1: only on sleep or screen lock."),
            ]),
            SettingsSection("Advanced", [
                f("keepass.cli", "keepassxc-cli path", .text(placeholder: "found automatically")),
                f("keepass.cliAccess", "Allow `hop kp get`", .toggle, "Lets the CLI (and agents) print passwords, TOTP codes and notes."),
            ]),
        ])
    }

    static var calendar: SettingsPage {
        SettingsPage(id: "calendar", title: "Calendar", subtitle: "Upcoming events and birthdays.",
                     symbol: "calendar", color: Palette.calendar, gate: ["calendar", "enabled"], sections: [
            SettingsSection([
                f("calendar.enabled", "Calendar", .toggle, "Asks for Calendar access."),
                f("calendar.soonMinutes", "Show events within", .number(min: 0, max: 1_440, unit: "min"),
                  "Root search shows events starting this soon, and ones running now."),
                f("calendar.days", "\"Calendar\" lists", .number(min: 1, max: 365, unit: "days")),
                f("calendar.birthdays", "Birthdays", .toggle, "Today's and tomorrow's at the top of root search."),
                f("calendar.ignoreCalendars", "Leave out", .list(placeholder: "Holidays"), "Calendar names, comma-separated."),
            ]),
        ])
    }

    static var messages: SettingsPage {
        SettingsPage(id: "messages", title: "Messages", subtitle: "Verification codes from SMS and iMessage.",
                     symbol: "message.fill", color: Palette.messages, gate: ["messages", "enabled"], sections: [
            SettingsSection([
                f("messages.enabled", "Messages codes", .toggle, "Needs Full Disk Access."),
                f("messages.pasteHotkey", "Paste latest code", .hotkey(optional: true)),
                f("messages.notify", "Notify", .toggle, "A HUD when a new code arrives."),
                f("messages.autoCopy", "Copy new codes", .toggle, "Hidden from clipboard history, cleared after 2 minutes."),
                f("messages.days", "List codes from the last", .number(min: 1, max: 365, unit: "days")),
                f("messages.latestMinutes", "Latest code within", .number(min: 1, max: 1_440, unit: "min"),
                  "\"Paste Latest Code\" takes only a code this recent."),
            ]),
        ])
    }

    static var bookmarks: SettingsPage {
        SettingsPage(id: "bookmarks", title: "Bookmarks", subtitle: "Links you can search from hop.",
                     symbol: "bookmark.fill", color: Theme.chart1, sections: [
            SettingsSection([
                .info(SettingsInfo(
                    label: "Bookmarks",
                    help: "Name, URL, aliases, icon and colour of each live in the config.",
                    lines: { config in config.bookmarks.map { "\($0.name)  ·  \($0.url)" } },
                    button: "Edit in Config", action: .openConfig)),
            ]),
        ])
    }

    static var system: SettingsPage {
        SettingsPage(id: "system", title: "System", subtitle: "System commands.",
                     symbol: "desktopcomputer", color: Palette.neutral, sections: [
            SettingsSection([
                f("system.downloadsFolder", "Downloads folder", .text(placeholder: "~/Downloads"), "Emptied by \"Clear Downloads\"."),
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

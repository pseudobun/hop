import Foundation
import Observation
import os

/// Contents of `~/.config/hop/config.json5`. Every key is optional; missing keys
/// fall back to the defaults below.
nonisolated struct HopConfig: Decodable, Equatable, Sendable {
    nonisolated struct General: Decodable, Equatable, Sendable {
        var hotkey = "cmd+space"
        var sensitivity: Sensitivity = .high
        var popToRootSeconds = 90
        /// Reopening the root search within this many seconds restores its query and row; 0 = off.
        var keepQueryFor = 10
        /// Rows under root results (and the only rows when nothing matches): ids from `FallbackSearch`.
        var fallbacks = ["chatgpt", "google", "github"]
        var openAtLogin = true
        var menuBarIcon = true
        /// "og" (Outfit + Geist Mono, warm black) or "modern" (system fonts, softer contrast).
        var theme: ThemeName = .og

        nonisolated enum ThemeName: String, Decodable, Equatable, Sendable, CaseIterable {
            case og, modern
        }
    }

    nonisolated struct HyperKey: Decodable, Equatable, Sendable {
        var enabled = false
        /// Caps Lock pressed and released alone sends Escape.
        var quickPressEscape = false
    }

    nonisolated struct WireGuard: Decodable, Equatable, Sendable {
        var enabled = true
        var showFlags = true
        /// Activating a tunnel deactivates the others first.
        var exclusive = true
        /// Tunnels as pills under the root search field.
        var bar = true
        /// Names shown in the bar, in this order; empty shows every tunnel.
        var barTunnels: [String] = []
        var keys = Keys()

        /// Launcher keys for the bar, in hotkey syntax ("cmd+j"); "" turns one off.
        nonisolated struct Keys: Decodable, Equatable, Sendable {
            /// Moves the keys into the bar: ←→ select, ↵ toggles, Esc back.
            var focus = "cmd+j"
            var disconnectAll = "cmd+shift+j"
            /// Modifiers for 1…9 that toggle a tunnel straight away, e.g. "alt+cmd"; "" = off.
            var direct = ""
        }
    }

    nonisolated struct KeePass: Decodable, Equatable, Sendable {
        nonisolated enum PasswordSource: String, Decodable, Equatable, Sendable, CaseIterable {
            /// Ask in hop once, remember it behind Touch ID / login password.
            case keychain
            /// Ask in hop every time the database is unlocked.
            case prompt
            /// Run `passwordCommand` and read the password from its stdout.
            case command
            /// The database has no master password (key file only).
            case none
        }

        nonisolated struct Database: Decodable, Equatable, Sendable {
            var name = ""
            var path = ""
            var keyFile = ""
            var password: PasswordSource = .keychain
            var passwordCommand = ""

            /// Label for pills and lists: `name`, or the file name without extension.
            var label: String { name.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : name }
            var expandedPath: String { path.expandingTilde }
        }

        var enabled = false
        /// Several databases; when empty, the single `database` keys below are used.
        var databases: [Database] = []
        var database = ""
        var keyFile = ""
        var password: PasswordSource = .keychain
        var passwordCommand = ""
        /// Lock on sleep, screen lock and after `lockAfterMinutes`; off keeps databases
        /// unlocked until locked by hand or hop quits.
        var autoLock = false
        /// Minutes of inactivity before locking (with `autoLock`); -1 never.
        var lockAfterMinutes = 10
        /// Override the keepassxc-cli path.
        var cli = ""
        /// Let `hop kp get` print passwords, TOTP codes and notes (for agents).
        var cliAccess = false
        /// Show site icons, fetched directly from each entry's site.
        var favicons = true

        /// Configured databases, including the legacy single-database keys.
        var allDatabases: [Database] {
            if !databases.isEmpty { return databases.filter { !$0.path.isEmpty } }
            guard !database.isEmpty else { return [] }
            return [Database(name: "", path: database, keyFile: keyFile, password: password, passwordCommand: passwordCommand)]
        }
    }

    nonisolated struct System: Decodable, Equatable, Sendable {
        var downloadsFolder = "~/Downloads"
    }

    /// A link searchable from the root, opened in the default browser.
    nonisolated struct Bookmark: Decodable, Equatable, Sendable {
        var name = ""
        var url = ""
        /// Other names that find it, e.g. "hass" for Home Assistant.
        var aliases: [String] = []
        /// Image file (absolute, ~/ or relative to the config folder), SF Symbol name or emoji.
        var icon = ""
        /// Tile colour for an SF Symbol icon, "#rrggbb".
        var color = ""
        /// Shown next to the name; defaults to the URL without its scheme.
        var subtitle = ""
    }

    nonisolated struct Notes: Decodable, Equatable, Sendable {
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

    nonisolated struct Clipboard: Decodable, Equatable, Sendable {
        var enabled = true
        var hotkey = "shift+alt+c"
        /// Days to keep unpinned entries; -1 keeps them forever.
        var keepDays = 90
        var maxItems = 2000
        /// Keep copied images (stored as PNG next to the history).
        var images = true
        /// Larger images are not kept.
        var maxImageMB = 20
        /// Apps whose copies are never recorded (bundle identifiers).
        var ignoreApps = ["com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
                          "com.1password.1password", "com.bitwarden.desktop"]
        /// ↵ pastes into the app you were in; false only copies.
        var pasteOnReturn = true
        /// Let `hop clip` read the history (for agents); it can hold anything you copied.
        var cliAccess = false
    }

    nonisolated struct Snippets: Decodable, Equatable, Sendable {
        var enabled = true
        /// Replace a snippet's keyword with the snippet as soon as it is typed (Accessibility).
        var expand = true
        /// Also expand keywords typed in the middle of a word.
        var expandWithinWords = false
        /// Apps where keywords never expand (bundle identifiers).
        var disabledApps: [String] = []
        var file = "~/.config/hop/snippets.json5"
    }

    nonisolated struct Files: Decodable, Equatable, Sendable {
        var enabled = true
        /// Folders Spotlight searches.
        var scopes = ["~"]
        /// Path components that hide a result.
        var exclude = ["node_modules", ".git", "Library", "DerivedData", ".Trash", ".cache", "Caches"]
        /// Also list files whose text matches (Spotlight's content index).
        var contentSearch = true
        var maxResults = 60
        /// Show dotfiles when browsing a path.
        var showHidden = false
    }

    nonisolated struct Shelf: Decodable, Equatable, Sendable {
        var enabled = true
        /// Shake the pointer while dragging to open a shelf under it.
        var shake = true
        var shakeSensitivity: ShakeDetector.Sensitivity = .medium
        /// Hold exactly these modifiers while dragging to open a shelf; "" turns it off.
        var modifier = "shift"
        /// New empty shelf, new shelf from the clipboard, reopen the last closed shelf.
        var hotkey = ""
        var clipboardHotkey = ""
        var reopenHotkey = ""
        /// Dragged-out items stay on the shelf.
        var keepAfterDragOut = false
        /// Drags that start in these apps never open a shelf (bundle identifiers).
        var ignoreApps: [String] = []
    }

    nonisolated struct Messages: Decodable, Equatable, Sendable {
        var enabled = true
        /// How far back "Messages Codes" looks.
        var days = 3
        /// "Paste Latest Code" only takes a code this recent.
        var latestMinutes = 15
        /// A HUD when a new code arrives.
        var notify = true
        /// Global hotkey for "Paste Latest Code"; "" turns it off.
        var pasteHotkey = "alt+cmd+v"
        /// Put a new code on the clipboard (concealed, cleared after two minutes).
        var autoCopy = false
    }

    nonisolated struct CalendarSettings: Decodable, Equatable, Sendable {
        var enabled = true
        /// Root search shows events starting within this many minutes (and ones running now).
        var soonMinutes = 60
        /// How many days "Calendar" lists.
        var days = 7
        /// Today's and tomorrow's birthdays at the top of root search.
        var birthdays = true
        /// Calendars to leave out, by name.
        var ignoreCalendars: [String] = []
    }

    nonisolated struct Emoji: Decodable, Equatable, Sendable {
        var enabled = true
        /// none, light, mediumLight, medium, mediumDark or dark; for emoji that take one.
        var skinTone = "none"
        /// Ask OpenAI for emoji when the index finds little (needs a key: "Set OpenAI API Key").
        var ai = true
        /// The cheapest current model is plenty for picking emoji.
        var aiModel = "gpt-6-luna"
        /// reasoning_effort ("none" answers in about 1.5 s); "" omits it.
        var aiReasoning = "none"
    }

    nonisolated struct Translate: Decodable, Equatable, Sendable {
        var enabled = true
        /// Translations are rare and should read well: a strong model, not the cheapest.
        var model = "gpt-6.1-terra"
        /// reasoning_effort; "" leaves it out.
        var reasoning = "none"
        /// Two ISO 639 codes: text in the first goes to the second, anything else to the first.
        /// Empty: the macOS language and English.
        var languages: [String] = []
    }

    nonisolated struct OCR: Decodable, Equatable, Sendable {
        var enabled = true
        /// Vision recognition languages, most likely first ("en-US", "de-DE", "sl-SI").
        var languages = ["en-US"]
    }

    /// The Agents panel: Claude Code and OpenCode sessions here and on SSH hosts.
    nonisolated struct Agents: Decodable, Equatable, Sendable {
        nonisolated enum Terminal: String, Decodable, Equatable, Sendable, CaseIterable {
            /// Ghostty, then iTerm, then Terminal: the first one installed.
            case auto, ghostty, iterm, terminal
        }

        /// What new sessions run in: tmux, or herdr (herdr.dev) with tmux as the fallback.
        nonisolated enum Multiplexer: String, Decodable, Equatable, Sendable, CaseIterable {
            case tmux, herdr
        }

        nonisolated struct Provider: Decodable, Equatable, Sendable {
            var enabled = true
            /// Path to the binary; "" finds it in the usual places (and the login PATH).
            var binary = ""
            /// Flags added to every session it starts, e.g. ["--model", "opus"].
            var args: [String] = []
        }

        nonisolated struct Claude: Decodable, Equatable, Sendable {
            var enabled = true
            var binary = ""
            var args: [String] = []
            /// Start sessions with --remote-control, so the Claude app and claude.ai/code can continue them.
            var remoteControl = true
        }

        /// A machine reached over SSH; its sessions are listed and new ones start there in tmux.
        nonisolated struct Host: Decodable, Equatable, Sendable {
            /// Shown in the panel; defaults to `ssh`.
            var name = ""
            /// Host alias from ~/.ssh/config (or user@host).
            var ssh = ""
            /// Where new sessions start when no folder is typed.
            var cwd = "~"
            /// Folders offered when starting a session there.
            var projects: [String] = []
            /// Binaries on that host (its login PATH finds them).
            var claude = "claude"
            var opencode = "opencode"
            /// "tmux" or "herdr" for new sessions there; nil follows `agents.multiplexer`.
            var multiplexer: Multiplexer?
            /// herdr on that host (its login PATH finds it).
            var herdr = "herdr"

            var label: String { name.isEmpty ? ssh : name }
        }

        var enabled = true
        var hotkey = "shift+cmd+space"
        var defaultProvider: AgentProvider = .claude
        /// Where new local sessions start when no folder is typed.
        var defaultCwd = "~/repos"
        /// Their subfolders are offered as projects when starting a session.
        var projectRoots = ["~/repos"]
        /// Finished sessions from this many hours back stay in the list.
        var historyHours = 24
        /// Where "Attach in Terminal" opens.
        var terminal: Terminal = .auto
        /// Path to tmux; "" finds it.
        var tmux = ""
        /// What new sessions run in; herdr falls back to tmux when it is missing or unreachable.
        var multiplexer: Multiplexer = .tmux
        /// Path to herdr; "" finds it.
        var herdr = ""
        /// Above other windows while open; false lets other windows cover it.
        var floating = true
        /// Seconds between remote host refreshes while the panel is open.
        var remoteRefreshSeconds = 15
        var claude = Claude()
        var opencode = Provider()
        var hosts: [Host] = []
    }

    nonisolated struct CalculatorSettings: Decodable, Equatable, Sendable {
        /// Convert currencies; rates come from open.er-api.com, only once you type one.
        var currencies = true
        /// The currency an amount converts to when no target is typed.
        var currency = "EUR"
    }

    var general = General()
    var hyperKey = HyperKey()
    var wireguard = WireGuard()
    var keepass = KeePass()
    var system = System()
    var bookmarks: [Bookmark] = []
    var notes = Notes()
    var clipboard = Clipboard()
    var snippets = Snippets()
    var files = Files()
    var calculator = CalculatorSettings()
    var shelf = Shelf()
    var messages = Messages()
    var calendar = CalendarSettings()
    var translate = Translate()
    var ocr = OCR()
    var emoji = Emoji()
    var agents = Agents()
    /// Global hotkeys for any command or app: { "Empty Trash": "hyper+t", "Safari": "hyper+s" }.
    var hotkeys: [String: String] = [:]

    init() {}
}

// MARK: - Lenient decoding (missing keys keep their defaults)

nonisolated private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

nonisolated extension HopConfig {
    private enum Keys: String, CodingKey { case general, hyperKey, wireguard, keepass, system, bookmarks, notes, clipboard, snippets, files, calculator, shelf, messages, calendar, translate, ocr, emoji, agents, hotkeys }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        general = try c.value(.general, General())
        hyperKey = try c.value(.hyperKey, HyperKey())
        wireguard = try c.value(.wireguard, WireGuard())
        keepass = try c.value(.keepass, KeePass())
        system = try c.value(.system, System())
        bookmarks = try c.value(.bookmarks, [])
        notes = try c.value(.notes, Notes())
        clipboard = try c.value(.clipboard, Clipboard())
        snippets = try c.value(.snippets, Snippets())
        files = try c.value(.files, Files())
        calculator = try c.value(.calculator, CalculatorSettings())
        shelf = try c.value(.shelf, Shelf())
        messages = try c.value(.messages, Messages())
        calendar = try c.value(.calendar, CalendarSettings())
        translate = try c.value(.translate, Translate())
        ocr = try c.value(.ocr, OCR())
        emoji = try c.value(.emoji, Emoji())
        agents = try c.value(.agents, Agents())
        hotkeys = try c.value(.hotkeys, [:])
    }
}

nonisolated extension HopConfig.General {
    private enum Keys: String, CodingKey { case hotkey, sensitivity, popToRootSeconds, keepQueryFor, fallbacks, openAtLogin, menuBarIcon, theme }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        hotkey = try c.value(.hotkey, d.hotkey)
        sensitivity = try c.value(.sensitivity, d.sensitivity)
        popToRootSeconds = try c.value(.popToRootSeconds, d.popToRootSeconds)
        keepQueryFor = try c.value(.keepQueryFor, d.keepQueryFor)
        fallbacks = try c.value(.fallbacks, d.fallbacks)
        openAtLogin = try c.value(.openAtLogin, d.openAtLogin)
        menuBarIcon = try c.value(.menuBarIcon, d.menuBarIcon)
        theme = try c.value(.theme, d.theme)
    }
}

nonisolated extension HopConfig.HyperKey {
    private enum Keys: String, CodingKey { case enabled, quickPressEscape }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        quickPressEscape = try c.value(.quickPressEscape, d.quickPressEscape)
    }
}

nonisolated extension HopConfig.WireGuard {
    private enum Fields: String, CodingKey { case enabled, showFlags, exclusive, bar, barTunnels, keys }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Fields.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        showFlags = try c.value(.showFlags, d.showFlags)
        exclusive = try c.value(.exclusive, d.exclusive)
        bar = try c.value(.bar, d.bar)
        barTunnels = try c.value(.barTunnels, d.barTunnels)
        keys = try c.value(.keys, d.keys)
    }
}

nonisolated extension HopConfig.WireGuard.Keys {
    private enum Keys: String, CodingKey { case focus, disconnectAll, direct }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        focus = try c.value(.focus, d.focus)
        disconnectAll = try c.value(.disconnectAll, d.disconnectAll)
        direct = try c.value(.direct, d.direct)
    }
}

nonisolated extension HopConfig.KeePass {
    private enum Keys: String, CodingKey { case enabled, databases, database, keyFile, password, passwordCommand, autoLock, lockAfterMinutes, cli, cliAccess, favicons }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        databases = try c.value(.databases, d.databases)
        database = try c.value(.database, d.database)
        keyFile = try c.value(.keyFile, d.keyFile)
        password = try c.value(.password, d.password)
        passwordCommand = try c.value(.passwordCommand, d.passwordCommand)
        autoLock = try c.value(.autoLock, d.autoLock)
        lockAfterMinutes = try c.value(.lockAfterMinutes, d.lockAfterMinutes)
        cli = try c.value(.cli, d.cli)
        cliAccess = try c.value(.cliAccess, d.cliAccess)
        favicons = try c.value(.favicons, d.favicons)
    }
}

nonisolated extension HopConfig.KeePass.Database {
    private enum Keys: String, CodingKey { case name, path, keyFile, password, passwordCommand }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        name = try c.value(.name, d.name)
        path = try c.value(.path, d.path)
        keyFile = try c.value(.keyFile, d.keyFile)
        password = try c.value(.password, d.password)
        passwordCommand = try c.value(.passwordCommand, d.passwordCommand)
    }
}

nonisolated extension HopConfig.System {
    private enum Keys: String, CodingKey { case downloadsFolder }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        downloadsFolder = try c.value(.downloadsFolder, d.downloadsFolder)
    }
}

nonisolated extension HopConfig.Bookmark {
    private enum Keys: String, CodingKey { case name, url, aliases, icon, color, subtitle }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        name = try c.value(.name, d.name)
        url = try c.value(.url, d.url)
        aliases = try c.value(.aliases, d.aliases)
        icon = try c.value(.icon, d.icon)
        color = try c.value(.color, d.color)
        subtitle = try c.value(.subtitle, d.subtitle)
    }
}

nonisolated extension HopConfig.CalculatorSettings {
    private enum Keys: String, CodingKey { case currencies, currency }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        currencies = try c.value(.currencies, d.currencies)
        currency = try c.value(.currency, d.currency)
    }
}

nonisolated extension HopConfig.Shelf {
    private enum Keys: String, CodingKey { case enabled, shake, shakeSensitivity, modifier, hotkey, clipboardHotkey, reopenHotkey, keepAfterDragOut, ignoreApps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        shake = try c.value(.shake, d.shake)
        shakeSensitivity = try c.value(.shakeSensitivity, d.shakeSensitivity)
        modifier = try c.value(.modifier, d.modifier)
        hotkey = try c.value(.hotkey, d.hotkey)
        clipboardHotkey = try c.value(.clipboardHotkey, d.clipboardHotkey)
        reopenHotkey = try c.value(.reopenHotkey, d.reopenHotkey)
        keepAfterDragOut = try c.value(.keepAfterDragOut, d.keepAfterDragOut)
        ignoreApps = try c.value(.ignoreApps, d.ignoreApps)
    }
}

nonisolated extension HopConfig.Messages {
    private enum Keys: String, CodingKey { case enabled, days, latestMinutes, notify, pasteHotkey, autoCopy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        days = try c.value(.days, d.days)
        latestMinutes = try c.value(.latestMinutes, d.latestMinutes)
        notify = try c.value(.notify, d.notify)
        pasteHotkey = try c.value(.pasteHotkey, d.pasteHotkey)
        autoCopy = try c.value(.autoCopy, d.autoCopy)
    }
}

nonisolated extension HopConfig.Emoji {
    private enum Keys: String, CodingKey { case enabled, skinTone, ai, aiModel, aiReasoning }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        skinTone = try c.value(.skinTone, d.skinTone)
        ai = try c.value(.ai, d.ai)
        aiModel = try c.value(.aiModel, d.aiModel)
        aiReasoning = try c.value(.aiReasoning, d.aiReasoning)
    }
}

nonisolated extension HopConfig.Agents {
    private enum Keys: String, CodingKey {
        case enabled, hotkey, defaultProvider, defaultCwd, projectRoots, historyHours, terminal, tmux, multiplexer, herdr, floating,
             remoteRefreshSeconds, claude, opencode, hosts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        hotkey = try c.value(.hotkey, d.hotkey)
        defaultProvider = try c.value(.defaultProvider, d.defaultProvider)
        defaultCwd = try c.value(.defaultCwd, d.defaultCwd)
        projectRoots = try c.value(.projectRoots, d.projectRoots)
        historyHours = try c.value(.historyHours, d.historyHours)
        terminal = try c.value(.terminal, d.terminal)
        tmux = try c.value(.tmux, d.tmux)
        multiplexer = try c.value(.multiplexer, d.multiplexer)
        herdr = try c.value(.herdr, d.herdr)
        floating = try c.value(.floating, d.floating)
        remoteRefreshSeconds = try c.value(.remoteRefreshSeconds, d.remoteRefreshSeconds)
        claude = try c.value(.claude, d.claude)
        opencode = try c.value(.opencode, d.opencode)
        hosts = try c.value(.hosts, d.hosts)
    }
}

nonisolated extension HopConfig.Agents.Provider {
    private enum Keys: String, CodingKey { case enabled, binary, args }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        binary = try c.value(.binary, d.binary)
        args = try c.value(.args, d.args)
    }
}

nonisolated extension HopConfig.Agents.Claude {
    private enum Keys: String, CodingKey { case enabled, binary, args, remoteControl }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        binary = try c.value(.binary, d.binary)
        args = try c.value(.args, d.args)
        remoteControl = try c.value(.remoteControl, d.remoteControl)
    }
}

nonisolated extension HopConfig.Agents.Host {
    private enum Keys: String, CodingKey { case name, ssh, cwd, projects, claude, opencode, multiplexer, herdr }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        name = try c.value(.name, d.name)
        ssh = try c.value(.ssh, d.ssh)
        cwd = try c.value(.cwd, d.cwd)
        projects = try c.value(.projects, d.projects)
        claude = try c.value(.claude, d.claude)
        opencode = try c.value(.opencode, d.opencode)
        multiplexer = try c.decodeIfPresent(HopConfig.Agents.Multiplexer.self, forKey: .multiplexer)
        herdr = try c.value(.herdr, d.herdr)
    }
}

nonisolated extension HopConfig.Agents {
    /// What new sessions on `host` (nil: this Mac) run in.
    func multiplexer(for host: Host?) -> Multiplexer { host?.multiplexer ?? multiplexer }
}

nonisolated extension HopConfig.CalendarSettings {
    private enum Keys: String, CodingKey { case enabled, soonMinutes, days, birthdays, ignoreCalendars }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        soonMinutes = try c.value(.soonMinutes, d.soonMinutes)
        days = try c.value(.days, d.days)
        birthdays = try c.value(.birthdays, d.birthdays)
        ignoreCalendars = try c.value(.ignoreCalendars, d.ignoreCalendars)
    }
}

nonisolated extension HopConfig.Translate {
    private enum Keys: String, CodingKey { case enabled, model, reasoning, languages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        model = try c.value(.model, d.model)
        reasoning = try c.value(.reasoning, d.reasoning)
        languages = try c.value(.languages, d.languages)
    }
}

nonisolated extension HopConfig.OCR {
    private enum Keys: String, CodingKey { case enabled, languages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        languages = try c.value(.languages, d.languages)
    }
}

nonisolated extension HopConfig.Files {
    private enum Keys: String, CodingKey { case enabled, scopes, exclude, contentSearch, maxResults, showHidden }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        scopes = try c.value(.scopes, d.scopes)
        exclude = try c.value(.exclude, d.exclude)
        contentSearch = try c.value(.contentSearch, d.contentSearch)
        maxResults = try c.value(.maxResults, d.maxResults)
        showHidden = try c.value(.showHidden, d.showHidden)
    }
}

nonisolated extension HopConfig.Snippets {
    private enum Keys: String, CodingKey { case enabled, expand, expandWithinWords, disabledApps, file }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        expand = try c.value(.expand, d.expand)
        expandWithinWords = try c.value(.expandWithinWords, d.expandWithinWords)
        disabledApps = try c.value(.disabledApps, d.disabledApps)
        file = try c.value(.file, d.file)
    }
}

nonisolated extension HopConfig.Clipboard {
    private enum Keys: String, CodingKey { case enabled, hotkey, keepDays, maxItems, images, maxImageMB, ignoreApps, pasteOnReturn, cliAccess }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        hotkey = try c.value(.hotkey, d.hotkey)
        keepDays = try c.value(.keepDays, d.keepDays)
        maxItems = try c.value(.maxItems, d.maxItems)
        images = try c.value(.images, d.images)
        maxImageMB = try c.value(.maxImageMB, d.maxImageMB)
        ignoreApps = try c.value(.ignoreApps, d.ignoreApps)
        pasteOnReturn = try c.value(.pasteOnReturn, d.pasteOnReturn)
        cliAccess = try c.value(.cliAccess, d.cliAccess)
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

nonisolated extension String {
    /// `~/x` → `/Users/me/x`; empty stays empty.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}

// MARK: - Loader

/// The user's config file, reloaded whenever it changes on disk. hop never writes
/// it except to create the commented template on first launch.
@Observable
final class AppSettings {
    private(set) var data = HopConfig()
    /// Parse error of the last load, shown as a row in the launcher.
    private(set) var error: ConfigIssue?
    /// Unknown keys (typos) in the last good load; the config still applies.
    private(set) var warnings: [ConfigIssue] = []

    @ObservationIgnored var onChange: ((HopConfig, HopConfig) -> Void)?
    @ObservationIgnored let url: URL
    @ObservationIgnored private var watcher: FileWatcher?
    /// The problem last shown in the HUD, so a save that changes nothing stays quiet.
    @ObservationIgnored private var announced: ConfigIssue?

    /// `$HOP_CONFIG` overrides the location (handy for tests and agents).
    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["HOP_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override.expandingTilde)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/hop/config.json5")
    }

    init(url: URL = AppSettings.defaultURL) {
        self.url = url
        load()
    }

    /// Creates the template if needed, loads it and starts watching its directory
    /// (editors save by replacing the file).
    func start() {
        if !FileManager.default.fileExists(atPath: url.path) { writeTemplate() }
        load()
        watch()
    }

    /// `announce` (after a save) shows a new error or warning in the HUD right away.
    func load(announce: Bool = false) {
        let old = data
        defer { if announce { announceProblem() } }
        guard let raw = try? Data(contentsOf: url) else {
            data = HopConfig()
            error = nil
            warnings = []
            if old != data { onChange?(old, data) }
            return
        }
        let text = String(decoding: raw, as: UTF8.self)
        do {
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = true
            data = try decoder.decode(HopConfig.self, from: raw)
            error = nil
            warnings = ConfigDiagnostics.warnings(in: text)
        } catch {
            self.error = ConfigDiagnostics.issue(for: error, in: text)
            warnings = []
            Log.app.error("config: \(self.error?.message ?? "", privacy: .public)")
            return // keep the last good config
        }
        if old != data { onChange?(old, data) }
    }

    private func announceProblem() {
        let current = error ?? warnings.first
        defer { announced = current }
        guard let current, current != announced else { return }
        if error != nil { HUD.shared.fail("Config: \(current.message)") } else { HUD.shared.warn("Config: \(current.message)") }
    }

    private func watch() {
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in self?.load(announce: true) }
    }

    private func writeTemplate() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.template.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("config template: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let template = """
    // hop configuration (JSON5: comments and trailing commas are fine).
    // Saved changes apply immediately. Delete a key to use its default.
    {
      general: {
        // cmd, ctrl, alt/opt, shift or hyper, plus a key: "cmd+space", "alt+space", "hyper+k"
        hotkey: "cmd+space",
        // How loosely search matches: "low", "medium" or "high"
        sensitivity: "high",
        // Reopening after this many seconds starts back at the root search
        popToRootSeconds: 90,
        // Reopening within this many seconds brings back the last root search, selected so
        // typing replaces it; 0 always starts empty. Capped by popToRootSeconds.
        keepQueryFor: 10,
        // Shown under root results, and alone when nothing matches (↵ runs the first):
        // "chatgpt", "google", "github", or a URL with {query}, e.g. "https://duckduckgo.com/?q={query}"
        fallbacks: ["chatgpt", "google", "github"],
        openAtLogin: true,
        menuBarIcon: true,
        // "og" or "modern" (system fonts, softer contrast); hop restarts to switch
        theme: "og",
      },

      // Global hotkeys for any command or app, on top of general.hotkey, notes.hotkey and
      // clipboard.hotkey. Key: a command title ("Empty Trash"), an app name ("Safari"),
      // a command id or "app:" + bundle id; `hop hotkeys` lists them. Value: e.g. "hyper+t".
      hotkeys: {
        // "Empty Trash": "hyper+t",
        // "Safari": "hyper+s",
        // "WireGuard": "hyper+w",
      },

      hyperKey: {
        // Caps Lock becomes ⌃⌥⌘⇧ (needs Accessibility permission)
        enabled: false,
        // Caps Lock tapped on its own sends Escape
        quickPressEscape: false,
      },

      wireguard: {
        enabled: true,
        // Flag from a tunnel name prefix: "si-home" → 🇸🇮
        showFlags: true,
        // Activating a tunnel deactivates the others first (one tunnel at a time)
        exclusive: true,
        // Tunnels as pills under the search field, click one to toggle it
        bar: true,
        // Which tunnels the bar shows, in order; [] shows all, e.g. ["si-home", "Office"]
        barTunnels: [],
        // Keys in the launcher, hotkey syntax; "" turns one off
        keys: {
          // Select in the bar: ←→ (Tab) move, ↵ or Space toggles, Esc goes back
          focus: "cmd+j",
          disconnectAll: "cmd+shift+j",
          // Modifiers for 1…9 to toggle a tunnel at once, e.g. "alt+cmd"
          direct: "",
        },
      },

      keepass: {
        enabled: false,
        // One entry per database; switch between them with ⌘D in hop.
        databases: [
          {
            name: "Personal",
            path: "~/Passwords.kdbx",
            // Optional key file
            keyFile: "",
            // Where the master password comes from (see below)
            password: "keychain",
            passwordCommand: "",
          },
          // { name: "Work", path: "~/Work/work.kdbx", password: "command",
          //   passwordCommand: "security find-generic-password -w -s hop-work" },
        ],
        // password: where a database's master password comes from. Never write it in this file.
        //   "keychain" ask once in hop, keep it in the Keychain behind Touch ID
        //   "prompt"   ask every time the database is unlocked
        //   "command"  run passwordCommand and read the password from its output,
        //              e.g. "security find-generic-password -w -s hop-keepass"
        //   "none"     the database has no password (key file only)
        // Lock again on sleep, when the screen locks and after lockAfterMinutes without use.
        // Off: an unlocked database stays open until you lock it (⌘L) or quit hop.
        autoLock: false,
        // With autoLock: minutes without use before locking; -1 only on sleep / screen lock
        lockAfterMinutes: 10,
        // Path to keepassxc-cli if it is not in KeePassXC.app or Homebrew
        cli: "",
        // Allow `hop kp get` to print passwords, TOTP codes and notes (e.g. for agents)
        cliAccess: false,
        // Site icons, fetched straight from each entry's website and cached
        favicons: true,
      },

      system: {
        // Folder emptied by "Clear Downloads"
        downloadsFolder: "~/Downloads",
      },

      // Links you can search from hop; ↵ opens them in the default browser.
      bookmarks: [
        // {
        //   name: "Home Assistant",
        //   url: "http://homeassistant.local:8123",
        //   // Other names that find it
        //   aliases: ["hass", "ha"],
        //   // Image file (relative to this folder, ~/ or absolute), SF Symbol name or emoji
        //   icon: "icons/home-assistant.svg",
        //   // Tile colour when icon is an SF Symbol
        //   color: "#18bcf2",
        // },
      ],

      notes: {
        enabled: true,
        // Opens the floating notes window from anywhere
        hotkey: "alt+.",
        // Folder of Markdown files; an Obsidian vault works as is, e.g. one in iCloud Drive:
        // "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<vault>"
        folder: "~/Notes",
        // Where ⌘N puts new notes, relative to folder
        newNoteFolder: "Inbox",
        // Start of every new note; {{title}} and {{date}} are filled in
        template: "---\\ntitle: {{title}}\\ntags: [inbox]\\ntype: note\\nstatus: stub\\nupdated: {{date}}\\n---\\n\\n",
        // Set an existing `updated:` date in the frontmatter to today when you edit a note
        bumpUpdated: true,
      },

      calculator: {
        // Currency conversion ("100 usd to eur", "€50 in gbp"); rates come from
        // open.er-api.com, fetched only after you type a currency, at most twice a day
        currencies: true,
        // Where an amount goes when you type no target ("50 usd")
        currency: "EUR",
      },

      files: {
        enabled: true,
        // Folders searched (Spotlight's index, so results are always current)
        scopes: ["~"],
        // Results with one of these folders in their path are hidden
        exclude: ["node_modules", ".git", "Library", "DerivedData", ".Trash", ".cache", "Caches"],
        // Also find files by the text inside them
        contentSearch: true,
        maxResults: 60,
        // Show dotfiles when browsing a path (~/…)
        showHidden: false,
      },

      shelf: {
        // Floating shelves to park files, links, images and text while you drag
        enabled: true,
        // Shake the pointer while dragging something to open a shelf under it
        shake: true,
        // "low", "medium" or "high": how small a shake counts
        shakeSensitivity: "medium",
        // Hold this while dragging to open a shelf ("shift", "alt", "ctrl+alt", "" off)
        modifier: "shift",
        // Global hotkeys: new empty shelf, new shelf from the clipboard, reopen the last one
        hotkey: "",
        clipboardHotkey: "",
        reopenHotkey: "",
        // Keep items on the shelf after you drag them out
        keepAfterDragOut: false,
        // Drags from these apps never open a shelf (bundle identifiers)
        ignoreApps: [],
      },

      messages: {
        // Verification codes from SMS and iMessage (needs Full Disk Access)
        enabled: true,
        // How many days back "Messages Codes" lists codes
        days: 3,
        // "Paste Latest Code" takes only a code received this many minutes ago or later
        latestMinutes: 15,
        // Show a HUD when a new code arrives, so it is ready to paste
        notify: true,
        // Global hotkey that pastes the latest code ("" off)
        pasteHotkey: "alt+cmd+v",
        // Also put a new code on the clipboard (hidden from clipboard history, cleared after 2 minutes)
        autoCopy: false,
      },

      calendar: {
        // Upcoming events and birthdays from Calendar (asks for Calendar access)
        enabled: true,
        // Root search shows events starting within this many minutes, and ones running now
        soonMinutes: 60,
        // How many days "Calendar" lists
        days: 7,
        // Today's and tomorrow's birthdays at the top of root search
        birthdays: true,
        // Calendars to leave out, by name
        ignoreCalendars: [],
      },

      emoji: {
        // "Search Emoji", or type ":" in hop: names, keywords (English, Slovenian) and slang
        enabled: true,
        // For emoji that take one: none, light, mediumLight, medium, mediumDark, dark
        skinTone: "none",
        // Suggestions from OpenAI for phrases the index can't place ("ko deploy faila v petek");
        // only with a key ("Set OpenAI API Key" in hop), only for those queries
        ai: true,
        aiModel: "gpt-6-luna",
        // reasoning_effort: "none" keeps it at about 1.5 s ("" leaves it out)
        aiReasoning: "none",
      },

      translate: {
        // "Translate" or "tr " in hop: between two languages with OpenAI ("Set OpenAI API Key")
        enabled: true,
        // ISO 639 codes: text in the first goes to the second, anything else to the first,
        // e.g. ["de", "en"] ([] = your macOS language and English)
        languages: [],
        model: "gpt-6.1-terra",
        // reasoning_effort ("none", "low", …; "" leaves it out)
        reasoning: "none",
      },

      ocr: {
        // "Copy Text from Screen": select an area, its text goes to the clipboard (read on this Mac)
        enabled: true,
        // Vision recognition languages, most likely first
        languages: ["en-US"],
      },

      agents: {
        // Agents panel: Claude Code and OpenCode sessions on this Mac and on SSH hosts,
        // live status and transcript; start new ones in tmux and attach from a terminal
        enabled: true,
        // Opens the panel (it follows you across Spaces until Esc); pressed again in front, it closes
        hotkey: "shift+cmd+space",
        // "claude" or "opencode": what a new session starts with
        defaultProvider: "claude",
        // Where new sessions start when no folder is typed
        defaultCwd: "~/repos",
        // Their subfolders are offered as projects when starting a session
        projectRoots: ["~/repos"],
        // Finished sessions from this many hours back stay in the list
        historyHours: 24,
        // "Attach in Terminal" (⌘↵): "auto", "ghostty", "iterm" or "terminal"
        terminal: "auto",
        // Path to tmux; "" finds it (Homebrew, /usr/local, PATH)
        tmux: "",
        // What new sessions run in: "tmux", or "herdr" (herdr.dev: hop lists its agents with
        // herdr's own status and can send them a prompt); herdr falls back to tmux when it is
        // not installed, its server is not running or speaks another protocol
        multiplexer: "tmux",
        // Path to herdr; "" finds it (Homebrew, ~/.local/bin, PATH)
        herdr: "",
        // Above other windows while open
        floating: true,
        // Seconds between refreshes of remote hosts while the panel is open
        remoteRefreshSeconds: 15,
        claude: {
          enabled: true,
          // "" finds claude (~/.local/bin, Homebrew, the login PATH)
          binary: "",
          // Flags for every session hop starts, e.g. ["--model", "opus"]
          args: [],
          // Start with --remote-control, so the Claude app and claude.ai/code can continue it
          remoteControl: true,
        },
        opencode: {
          enabled: true,
          binary: "",
          args: [],
        },
        // Machines reached over SSH: sessions there are listed (herdr's too, when it runs
        // there), new ones start there in tmux, or in herdr with multiplexer: "herdr"
        hosts: [
          // { name: "my-server", ssh: "my-server", cwd: "~", projects: ["~/code/app"], multiplexer: "herdr" },
        ],
      },

      snippets: {
        enabled: true,
        // Type a snippet's keyword anywhere and it becomes the snippet (needs Accessibility)
        expand: true,
        // Also expand keywords typed in the middle of a word
        expandWithinWords: false,
        // Apps where keywords never expand (bundle identifiers)
        disabledApps: [],
        // The snippets themselves (JSON5); "Edit Snippets" in hop opens it
        file: "~/.config/hop/snippets.json5",
      },

      clipboard: {
        enabled: true,
        // Opens the clipboard history from anywhere
        hotkey: "shift+alt+c",
        // Days to keep unpinned entries (-1 forever) and how many at most
        keepDays: 90,
        maxItems: 2000,
        // Keep copied images, up to this size
        images: true,
        maxImageMB: 20,
        // Copies from these apps are never recorded; password managers that mark their
        // copies as concealed (KeePassXC, 1Password, hop itself) are skipped anyway
        ignoreApps: ["com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
                     "com.1password.1password", "com.bitwarden.desktop"],
        // ↵ pastes into the app you were in; false only copies
        pasteOnReturn: true,
        // Let `hop clip` read the history (e.g. for agents); it holds whatever you copied
        cliAccess: false,
      },
    }

    """
}

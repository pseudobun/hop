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
        /// "og", "og-light", "modern", "solarpunk", "cyberpunk" or a custom theme's file name
        /// in `~/.config/hop/themes/`; see Theme and CustomThemes.
        var theme: ThemeName = .og
        /// macOS 26 Liquid Glass behind every hop window; false: the flat, mostly opaque look.
        var glass = true
        /// The glass material: "regular" (frosted, like Spotlight) or "clear" (barely frosted).
        var glassStyle = "regular"
        /// How much of the theme's background tints the glass, 0–100 %. Low: the wallpaper shows
        /// through as in Spotlight; high: close to the flat look.
        var glassTint = 20

        /// A built-in theme or a custom one (its file name without the extension).
        nonisolated struct ThemeName: RawRepresentable, Decodable, Hashable, Sendable, ExpressibleByStringLiteral {
            let rawValue: String
            init(rawValue: String) { self.rawValue = rawValue }
            init(stringLiteral value: String) { rawValue = value }
            init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

            static let og: ThemeName = "og"
            static let ogLight: ThemeName = "og-light"
            static let modern: ThemeName = "modern"
            static let solarpunk: ThemeName = "solarpunk"
            static let cyberpunk: ThemeName = "cyberpunk"
            /// The themes hop ships, in the order the picker lists them.
            static let builtIn: [ThemeName] = [.og, .ogLight, .modern, .solarpunk, .cyberpunk]
            var isBuiltIn: Bool { Self.builtIn.contains(self) }
        }
    }

    /// Sparkle updates from the appcast on GitHub; only release builds (Homebrew, release zip) check.
    nonisolated struct Updates: Decodable, Equatable, Sendable {
        /// Look for a new version once a day and download it in the background; it installs when hop quits.
        var check = true
        /// Install as soon as it is downloaded (hop restarts by itself).
        var automatic = false
        /// "stable", "beta" (stable versions and betas) or "auto": beta when the running hop is one.
        var channel = "auto"

        /// Whether betas are offered, for a running hop of `version`.
        func wantsBeta(running version: String) -> Bool {
            switch channel {
            case "beta": return true
            case "stable": return false
            default: return version.split(separator: "+")[0].contains("-")
            }
        }
    }

    var general = General()
    var updates = Updates()
    /// `plugins: { disabled: [...], "<id>": {...} }`: plugins turned off, and the settings of
    /// plugins installed from GitHub (built-in plugins keep their own top-level section).
    var plugins = Plugins()
    /// Global hotkeys for any command or app: { "Empty Trash": "hyper+t", "Safari": "hyper+s" }.
    var hotkeys: [String: String] = [:]
    /// The built-in plugins' sections (`notes: {…}`, `keepass: {…}`), each typed by its plugin.
    /// Not a JSON key itself: every section is a top-level key.
    var sections = PluginConfigs()

    nonisolated struct Plugins: Equatable, Sendable {
        /// Ids of plugins turned off that have no `enabled` key of their own.
        var disabled: [String] = []
        /// GitHub links (`owner/repo[@tag]`) hop keeps installed; nil leaves installed plugins alone.
        var install: [String]?
        /// Settings of installed plugins, by plugin id.
        var settings: [String: JSONValue] = [:]
    }

    init() {}
}

// MARK: - Lenient decoding (missing keys keep their defaults)

nonisolated extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

nonisolated extension HopConfig {
    private enum Keys: String, CodingKey { case general, updates, hotkeys, plugins }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        general = try c.value(.general, General())
        updates = try c.value(.updates, Updates())
        hotkeys = try c.value(.hotkeys, [:])
        plugins = try c.value(.plugins, Plugins())
        sections = try PluginConfigs(from: decoder)
    }
}

nonisolated extension HopConfig.Updates {
    private enum Keys: String, CodingKey { case check, automatic, channel }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        check = try c.value(.check, d.check)
        automatic = try c.value(.automatic, d.automatic)
        channel = try c.value(.channel, d.channel)
    }
}

nonisolated extension HopConfig.General {
    private enum Keys: String, CodingKey { case hotkey, sensitivity, popToRootSeconds, keepQueryFor, fallbacks, openAtLogin, menuBarIcon, theme, glass, glassStyle, glassTint }
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
        glass = try c.value(.glass, d.glass)
        glassStyle = try c.value(.glassStyle, d.glassStyle)
        glassTint = min(max(try c.value(.glassTint, d.glassTint), 0), 100)
    }
}



















nonisolated extension String {
    /// `~/x` → `/Users/me/x`; empty stays empty.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}

// MARK: - Loader

/// The user's config file, reloaded whenever it changes on disk. hop writes it only to
/// create the commented template on first launch and for changes made in Settings or
/// the Theme picker, one value at a time, keeping comments.
@Observable
final class AppSettings {
    private(set) var data = HopConfig()
    /// Parse error of the last load, shown as a row in the launcher.
    private(set) var error: ConfigIssue?
    /// Unknown keys (typos) in the last good load; the config still applies.
    private(set) var warnings: [ConfigIssue] = []

    @ObservationIgnored var onChange: ((HopConfig, HopConfig) -> Void)?
    /// `error` or `warnings` changed while the config itself did not (a broken save, its fix,
    /// a typo): what shows them (the launcher's Setup rows, Settings) refreshes.
    @ObservationIgnored var onStatusChange: (() -> Void)?
    @ObservationIgnored let url: URL
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var envWatcher: FileWatcher?
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

    /// Creates the template if needed, loads it (a problem in it shows in the HUD, so hop does not
    /// run on defaults without a word) and starts watching it and its `.env`.
    func start() {
        if !FileManager.default.fileExists(atPath: url.path) { writeTemplate() }
        load(announce: true)
        watch()
    }

    /// `announce` (after a save) shows a new error or warning in the HUD right away.
    func load(announce: Bool = false) {
        let old = data, oldError = error, oldWarnings = warnings
        defer {
            if announce { announceProblem() }
            if old != data { onChange?(old, data) } else if oldError != error || oldWarnings != warnings { onStatusChange?() }
        }
        guard let raw = try? Data(contentsOf: url) else {
            // Gone for a moment (an editor or a dotfiles sync replacing it): keep the last good
            // config rather than turning every setting back to its default.
            Log.app.error("config: \(self.url.path, privacy: .public) can't be read, keeping the last config")
            return
        }
        let text = String(decoding: raw, as: UTF8.self)
        let (expanded, missing) = ConfigEnv.expand(text, env: ConfigEnv.load(beside: url))
        do {
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = true
            data = try decoder.decode(HopConfig.self, from: Data(expanded.utf8))
            error = nil
            warnings = missing.map { ConfigIssue(message: "${\($0)} is not set (.env beside the config)") }
                + ConfigDiagnostics.warnings(in: text)
        } catch {
            self.error = ConfigDiagnostics.issue(for: error, in: text)
            warnings = []
            Log.app.error("config: \(self.error?.message ?? "", privacy: .public)")
            // `data` stays: the last good config keeps applying.
        }
    }

    /// Writes one value into the file (comments and layout kept) and loads it, so it applies
    /// right away. `literal` is JSON5 source (`ConfigEdit.literal`). False when it can't be written.
    @discardableResult
    func update(_ path: [String], to literal: String) -> Bool {
        // Write through a symlink (dotfiles) instead of replacing it with a copy.
        let target = url.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: target, encoding: .utf8)) ?? "{\n}\n"
        guard let updated = ConfigEdit.setting(path, to: literal, in: text) else { return false }
        if updated == text { return true }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("config write: \(error.localizedDescription, privacy: .public)")
            return false
        }
        load(announce: true)
        return true
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
        // `${NAME}` values come from `.env`, often a symlink into dotfiles: watch the file it
        // points to (and that folder, for when it is replaced or created).
        envWatcher?.stop()
        envWatcher = FileWatcher(url: ConfigEnv.file(beside: url).resolvingSymlinksInPath()) { [weak self] in
            self?.load(announce: true)
        }
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
    // ${NAME} in any value is filled from .env beside this file (KEY=value lines).
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
        // "og", "og-light", "modern", "solarpunk", "cyberpunk" or your own:
        // a .json5 file in themes/ beside this file (`hop themes template` prints one).
        // The Theme command previews them all and can import or start a new one.
        theme: "og",
        // Liquid Glass (macOS 26) behind the launcher, clipboard, notes and HUD: the wallpaper
        // shows through, tinted with the theme. false: the flat, mostly opaque look.
        glass: true,
        // "regular" (frosted, like Spotlight) or "clear" (barely frosted, most see-through)
        glassStyle: "regular",
        // How much of the theme's background tints the glass, 0–100: 0 is bare glass,
        // 100 close to the flat look
        glassTint: 20,
      },

      // New versions from GitHub (Sparkle), for builds from Homebrew or a release zip (builds
      // from source don't check). Downloaded in the background without windows; the launcher
      // shows "Update hop" (and "Update paw") once one is ready, `hop update` installs it now.
      updates: {
        // Look once a day, download in the background, install when hop quits
        check: true,
        // Install as soon as it is downloaded; hop restarts
        automatic: false,
        // "stable", "beta" (betas too) or "auto" (beta when this hop is one)
        channel: "auto",
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

nonisolated extension HopConfig.Plugins: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PluginConfigs.AnyKey.self)
        for key in c.allKeys {
            if key.stringValue == "disabled" {
                disabled = try c.decode([String].self, forKey: key)
            } else if key.stringValue == "install" {
                install = try c.decode([String].self, forKey: key)
            } else {
                settings[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
            }
        }
    }
}

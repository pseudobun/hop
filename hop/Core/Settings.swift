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
        var openAtLogin = true
        var menuBarIcon = true
    }

    nonisolated struct HyperKey: Decodable, Equatable, Sendable {
        var enabled = false
        /// Caps Lock pressed and released alone sends Escape.
        var quickPressEscape = false
    }

    nonisolated struct WireGuard: Decodable, Equatable, Sendable {
        var enabled = true
        var showFlags = true
    }

    nonisolated struct KeePass: Decodable, Equatable, Sendable {
        nonisolated enum PasswordSource: String, Decodable, Equatable, Sendable {
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
        /// Minutes of inactivity before locking; -1 never.
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
        var folder = "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian"
        /// Where new notes go, relative to `folder`.
        var newNoteFolder = "Inbox"
        /// Start of every new note; `{{title}}` and `{{date}}` are filled in.
        var template = "---\ntitle: {{title}}\ntags: [inbox]\ntype: note\nstatus: stub\nupdated: {{date}}\n---\n\n"
        /// Set an existing `updated:` frontmatter date to today when a note is edited.
        var bumpUpdated = true

        var expandedFolder: String { folder.expandingTilde }
    }

    var general = General()
    var hyperKey = HyperKey()
    var wireguard = WireGuard()
    var keepass = KeePass()
    var system = System()
    var bookmarks: [Bookmark] = []
    var notes = Notes()

    init() {}
}

// MARK: - Lenient decoding (missing keys keep their defaults)

nonisolated private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

nonisolated extension HopConfig {
    private enum Keys: String, CodingKey { case general, hyperKey, wireguard, keepass, system, bookmarks, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        general = try c.value(.general, General())
        hyperKey = try c.value(.hyperKey, HyperKey())
        wireguard = try c.value(.wireguard, WireGuard())
        keepass = try c.value(.keepass, KeePass())
        system = try c.value(.system, System())
        bookmarks = try c.value(.bookmarks, [])
        notes = try c.value(.notes, Notes())
    }
}

nonisolated extension HopConfig.General {
    private enum Keys: String, CodingKey { case hotkey, sensitivity, popToRootSeconds, openAtLogin, menuBarIcon }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        hotkey = try c.value(.hotkey, d.hotkey)
        sensitivity = try c.value(.sensitivity, d.sensitivity)
        popToRootSeconds = try c.value(.popToRootSeconds, d.popToRootSeconds)
        openAtLogin = try c.value(.openAtLogin, d.openAtLogin)
        menuBarIcon = try c.value(.menuBarIcon, d.menuBarIcon)
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
    private enum Keys: String, CodingKey { case enabled, showFlags }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        showFlags = try c.value(.showFlags, d.showFlags)
    }
}

nonisolated extension HopConfig.KeePass {
    private enum Keys: String, CodingKey { case enabled, databases, database, keyFile, password, passwordCommand, lockAfterMinutes, cli, cliAccess, favicons }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        databases = try c.value(.databases, d.databases)
        database = try c.value(.database, d.database)
        keyFile = try c.value(.keyFile, d.keyFile)
        password = try c.value(.password, d.password)
        passwordCommand = try c.value(.passwordCommand, d.passwordCommand)
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
    private(set) var error: String?

    @ObservationIgnored var onChange: ((HopConfig, HopConfig) -> Void)?
    @ObservationIgnored let url: URL
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

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

    func load() {
        let old = data
        guard let raw = try? Data(contentsOf: url) else {
            data = HopConfig()
            error = nil
            if old != data { onChange?(old, data) }
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = true
            data = try decoder.decode(HopConfig.self, from: raw)
            error = nil
        } catch {
            self.error = Self.describe(error)
            Log.app.error("config: \(self.error ?? "", privacy: .public)")
            return // keep the last good config
        }
        if old != data { onChange?(old, data) }
    }

    private func watch() {
        let dir = url.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadTask?.cancel()
                self?.reloadTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.load()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func writeTemplate() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.template.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("config template: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let ctx) = error {
            let detail = (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return detail ?? ctx.debugDescription
        }
        if case DecodingError.typeMismatch(_, let ctx) = error {
            return "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        }
        if case DecodingError.dataCorrupted = error { return "invalid JSON5" }
        return error.localizedDescription
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
        openAtLogin: true,
        menuBarIcon: true,
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
      },

      keepass: {
        enabled: false,
        // One entry per database; switch between them with ⌘D in hop.
        databases: [
          {
            name: "Personal",
            path: "~/Documents/Passwords.kdbx",
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
        // Lock after this many minutes without use; -1 never
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
        // Folder of Markdown files; an Obsidian vault works as is
        folder: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian",
        // Where ⌘N puts new notes, relative to folder
        newNoteFolder: "Inbox",
        // Start of every new note; {{title}} and {{date}} are filled in
        template: "---\\ntitle: {{title}}\\ntags: [inbox]\\ntype: note\\nstatus: stub\\nupdated: {{date}}\\n---\\n\\n",
        // Set an existing `updated:` date in the frontmatter to today when you edit a note
        bumpUpdated: true,
      },
    }

    """
}

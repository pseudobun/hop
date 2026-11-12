import Foundation

nonisolated extension HopConfig {
    nonisolated struct KeePass: PluginConfig {
        static let key = "keepass"
        static var samples: [String: Any] { ["databases": Database()] }
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

    var keepass: KeePass {
        get { sections[KeePass.self] }
        set { sections[KeePass.self] = newValue }
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

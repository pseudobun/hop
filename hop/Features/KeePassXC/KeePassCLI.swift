import AppKit
import LocalAuthentication
import Security

nonisolated enum KeePassError: Error, Equatable {
    case notConfigured, cliNotFound, databaseMissing, invalidCredentials, cancelled
    case failed(String)

    var message: String {
        switch self {
        case .notConfigured: "Add a database to keepass.databases in the hop config"
        case .cliNotFound: "keepassxc-cli not found. Install KeePassXC or set keepass.cli"
        case .databaseMissing: "Database file not found"
        case .invalidCredentials: "Wrong password or key file"
        case .cancelled: "Cancelled"
        case .failed(let m): m
        }
    }
}

/// Wraps `keepassxc-cli` (as the Raycast extension does): the password goes on stdin,
/// entries come back as CSV and are only ever kept in memory.
nonisolated enum KeePassCLI {
    static func locate(override: String) -> String? {
        let fm = FileManager.default
        if !override.isEmpty { return fm.isExecutableFile(atPath: override.expandingTilde) ? override.expandingTilde : nil }
        var candidates: [String] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.keepassxc.keepassxc") {
            candidates.append(app.appending(path: "Contents/MacOS/keepassxc-cli").path)
        }
        candidates += ["/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli",
                       "/opt/homebrew/bin/keepassxc-cli", "/usr/local/bin/keepassxc-cli"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func arguments(_ command: String, database: String, keyFile: String, noPassword: Bool, extra: [String] = []) -> [String] {
        var args = [command, "-q"]
        if !keyFile.isEmpty { args += ["-k", keyFile.expandingTilde] }
        if noPassword { args.append("--no-password") }
        return args + extra + [database.expandingTilde]
    }

    static func export(cli: String, database: HopConfig.KeePass.Database, password: String?) async throws -> [KeePassEntry] {
        let db = database.expandedPath
        guard FileManager.default.fileExists(atPath: db) else { throw KeePassError.databaseMissing }
        let args = arguments("export", database: db, keyFile: database.keyFile, noPassword: password == nil, extra: ["-f", "csv"])
        let stdin = password.map { Data(($0 + "\n").utf8) }
        let r: ProcessResult
        do { r = try await ProcessRunner.run(cli, args, stdin: stdin ?? Data(), timeout: .seconds(60)) }
        catch { throw KeePassError.failed("Could not run keepassxc-cli") }
        guard r.ok else { throw classify(r.err, status: r.status) }
        return KeePassCSV.parse(r.out)
    }

    static func classify(_ stderr: String, status: Int32) -> KeePassError {
        if stderr.contains("Invalid credentials") || stderr.contains("Failed to load key file") || stderr.contains("Wrong key") {
            return .invalidCredentials
        }
        if stderr.contains("Failed to open database file") || stderr.contains("Not a KeePass database") {
            return .failed("Not a KeePass database")
        }
        let line = stderr.split(separator: "\n").map(String.init).first { !$0.contains("Enter password") } ?? ""
        return .failed(line.isEmpty ? "keepassxc-cli exited with \(status)" : line)
    }

    /// Runs `keepass.passwordCommand` through /bin/sh and returns its stdout without the final newline.
    static func passwordFromCommand(_ command: String) async throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let r = try await ProcessRunner.run("/bin/sh", ["-c", command], environment: env, timeout: .seconds(30))
        guard r.ok else { throw KeePassError.failed("passwordCommand failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        var out = r.out
        while out.hasSuffix("\n") || out.hasSuffix("\r") { out.removeLast() }
        return out
    }
}

/// The master password in the login Keychain, released only after Touch ID
/// (or the login password on Macs without Touch ID).
nonisolated enum CredentialVault {
    static let service = "dev.hop.app.keepass"

    static func save(_ password: String, account: String) -> Bool {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "hop KeePassXC master password",
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func hasPassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Touch ID or the login password.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

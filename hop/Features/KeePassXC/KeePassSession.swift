import AppKit

/// One unlocked database, in memory only, until it is locked by hand, hop quits, or
/// (with `keepass.autoLock`) inactivity, screen lock or sleep.
final class KeePassSession {
    enum State { case locked, unlocking, unlocked }

    let path: String
    private(set) var state: State = .locked
    private(set) var entries: [KeePassEntry] = []
    private(set) var lastError: KeePassError?
    private var password: String?
    private var databaseStamp: (Date, Int)?
    private var lockTask: Task<Void, Never>?
    private let settings: AppSettings
    var onChange: (() -> Void)?

    init(path: String, settings: AppSettings) {
        self.path = path
        self.settings = settings
    }

    var keepass: HopConfig.KeePass { settings.data.keepass }
    /// This database's config (falls back to a bare entry if it was removed).
    var database: HopConfig.KeePass.Database {
        keepass.allDatabases.first { $0.expandedPath == path } ?? .init(path: path)
    }
    var account: String { path }
    /// Looked up at most every 10 s: the search asks on every keystroke, and each lookup is a
    /// LaunchServices call plus a few `stat`s.
    var cliPath: String? {
        let override = keepass.cli
        if let c = cachedCLI, c.override == override, Date().timeIntervalSince(c.at) < 10 { return c.path }
        let path = KeePassCLI.locate(override: override)
        cachedCLI = (override, path, Date())
        return path
    }

    private var cachedCLI: (override: String, path: String?, at: Date)?

    /// Unlock with an explicit password (nil when the database has none).
    func unlock(password: String?) async throws {
        guard let cli = cliPath else { throw KeePassError.cliNotFound }
        state = .unlocking
        onChange?()
        do {
            entries = try await KeePassCLI.export(cli: cli, database: database, password: password)
            self.password = password
            databaseStamp = stamp()
            state = .unlocked
            lastError = nil
            touch()
        } catch let e as KeePassError {
            state = .locked
            lastError = e
            onChange?()
            throw e
        }
        onChange?()
    }

    /// Re-export if the database file changed since the last export.
    func refreshIfChanged() async {
        guard state == .unlocked, let stamp = stamp(), let old = databaseStamp, stamp != old else { return }
        try? await unlock(password: password)
    }

    /// Resets the inactivity timer (only with `keepass.autoLock`).
    func touch() {
        lockTask?.cancel()
        let minutes = keepass.lockAfterMinutes
        guard keepass.autoLock, minutes >= 0 else { return }
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(minutes, 1) * 60))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    func lock() {
        guard state != .locked else { return }
        lockTask?.cancel()
        entries = []
        password = nil
        databaseStamp = nil
        state = .locked
        onChange?()
    }

    private func stamp() -> (Date, Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let m = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
        return (m, s)
    }
}

/// All configured databases' sessions, the current selection, and locking on
/// sleep or screen lock when `keepass.autoLock` is on.
final class KeePassManager {
    enum Selection: Equatable { case database(String), all }

    private let settings: AppSettings
    private var sessions: [String: KeePassSession] = [:]
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoLockAll() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoLockAll() }
        })
    }

    var databases: [HopConfig.KeePass.Database] { settings.data.keepass.allDatabases }

    func session(_ path: String) -> KeePassSession {
        if let s = sessions[path] { return s }
        let s = KeePassSession(path: path, settings: settings)
        s.onChange = { [weak self] in self?.onChange?() }
        sessions[path] = s
        return s
    }

    var selection: Selection {
        get {
            let saved = UserDefaults.standard.string(forKey: "KeePassSelection") ?? ""
            if saved == "*" && databases.count > 1 { return .all }
            if let db = databases.first(where: { $0.expandedPath == saved }) { return .database(db.expandedPath) }
            return databases.first.map { .database($0.expandedPath) } ?? .all
        }
        set {
            let value = switch newValue {
            case .all: "*"
            case .database(let p): p
            }
            UserDefaults.standard.set(value, forKey: "KeePassSelection")
        }
    }

    func lockAll() { sessions.values.forEach { $0.lock() } }

    private func autoLockAll() {
        if settings.data.keepass.autoLock { lockAll() }
    }
}

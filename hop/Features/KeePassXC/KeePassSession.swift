import AppKit

/// The unlocked database lives here, in memory only, until it locks
/// (inactivity, screen lock, sleep or an explicit lock).
final class KeePassSession {
    enum State { case locked, unlocking, unlocked }

    private(set) var state: State = .locked
    private(set) var entries: [KeePassEntry] = []
    private(set) var lastError: KeePassError?
    private var password: String?
    private var databaseStamp: (Date, Int)?
    private var lockTask: Task<Void, Never>?
    private let settings: AppSettings
    private var observers: [NSObjectProtocol] = []

    var config: HopConfig.KeePass { settings.data.keepass }
    var account: String { config.database.expandingTilde }
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }

    var cliPath: String? { KeePassCLI.locate(override: config.cli) }

    /// Unlock with an explicit password (nil when the database has none).
    func unlock(password: String?) async throws {
        guard !config.database.isEmpty else { throw KeePassError.notConfigured }
        guard let cli = cliPath else { throw KeePassError.cliNotFound }
        state = .unlocking
        onChange?()
        do {
            entries = try await KeePassCLI.export(cli: cli, config: config, password: password)
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

    /// Resets the inactivity timer.
    func touch() {
        lockTask?.cancel()
        let minutes = config.lockAfterMinutes
        guard minutes >= 0 else { return }
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
        guard let a = try? FileManager.default.attributesOfItem(atPath: account),
              let m = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
        return (m, s)
    }
}

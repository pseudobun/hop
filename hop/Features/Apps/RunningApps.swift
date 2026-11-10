import AppKit

/// Item ids of apps that show in the Dock right now, kept current from NSWorkspace
/// launch/terminate notifications, plus a refresh each time hop opens: some apps (Find My)
/// quit without a terminate notification.
final class RunningApps {
    static let shared = RunningApps()

    private(set) var ids: Set<String> = []
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    /// `id` is an `AppEntry.id`: "app:" + bundle id, or "app:" + path for unbundled apps.
    func contains(_ id: String) -> Bool { ids.contains(id) }

    func refresh() {
        var next = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bundleID = app.bundleIdentifier { next.insert("app:" + bundleID) }
            if let path = app.bundleURL?.path { next.insert("app:" + path) }
        }
        guard next != ids else { return }
        ids = next
        onChange?()
    }
}

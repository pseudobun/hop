import AppKit

/// Says when nobody can be using hop: the screen is locked, the Mac is asleep or another
/// user's session is in front. Periodic work (clipboard polling, calendar refreshes, retry
/// timers) pauses while away and catches up on return; `onChange` fires on transitions only.
final class SystemActivity {
    enum Event: Equatable {
        case locked, unlocked, willSleep, didWake, sessionResigned, sessionActive
    }

    private(set) var locked = false
    private(set) var asleep = false
    private(set) var switchedOut = false
    var isAway: Bool { locked || asleep || switchedOut }
    /// Called with the new `isAway`.
    var onChange: ((Bool) -> Void)?
    /// Whether the screen is locked right now; asked on wake, in case an unlock was missed.
    var screenIsLocked: () -> Bool = SystemActivity.sessionScreenIsLocked

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name, Event)] = [
            (distributed, .init("com.apple.screenIsLocked"), .locked),
            (distributed, .init("com.apple.screenIsUnlocked"), .unlocked),
            (workspace, NSWorkspace.willSleepNotification, .willSleep),
            (workspace, NSWorkspace.didWakeNotification, .didWake),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
        ]
        for (center, name, event) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    func handle(_ event: Event) {
        let was = isAway
        switch event {
        case .locked: locked = true
        case .unlocked: locked = false
        case .willSleep: asleep = true
        case .didWake:
            asleep = false
            locked = screenIsLocked()
        case .sessionResigned: switchedOut = true
        case .sessionActive: switchedOut = false
        }
        if isAway != was { onChange?(isAway) }
    }

    /// The login session's lock flag (the same one the screenIsLocked notification reports).
    nonisolated static func sessionScreenIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

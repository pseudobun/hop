import AppKit
import Testing
@testable import hop

@MainActor
struct SystemActivityTests {
    private func activity(lockedOnWake: Bool = false) -> (SystemActivity, () -> [Bool]) {
        let a = SystemActivity()
        a.screenIsLocked = { lockedOnWake }
        var changes: [Bool] = []
        a.onChange = { changes.append($0) }
        return (a, { changes })
    }

    @Test func lockAndUnlockPauseAndResume() {
        let (a, changes) = activity()
        a.handle(.locked)
        #expect(a.isAway)
        a.handle(.unlocked)
        #expect(!a.isAway)
        #expect(changes() == [true, false])
    }

    /// Lock, then sleep, then wake to the lock screen: away the whole time, one change each way.
    @Test func sleepWhileLockedStaysAwayUntilUnlock() {
        let (a, changes) = activity(lockedOnWake: true)
        a.handle(.locked)
        a.handle(.willSleep)
        a.handle(.didWake)
        #expect(a.isAway)
        a.handle(.unlocked)
        #expect(!a.isAway)
        #expect(changes() == [true, false])
    }

    /// A missed unlock notification must not pause hop for good: wake asks the session.
    @Test func wakeResyncsTheLockFlag() {
        let (a, changes) = activity(lockedOnWake: false)
        a.handle(.locked)
        a.handle(.willSleep)
        a.handle(.didWake)
        #expect(!a.isAway)
        #expect(changes() == [true, false])
    }

    @Test func switchedOutSessionIsAway() {
        let (a, changes) = activity()
        a.handle(.sessionResigned)
        a.handle(.locked)
        a.handle(.unlocked)
        #expect(a.isAway)
        a.handle(.sessionActive)
        #expect(!a.isAway)
        #expect(changes() == [true, false])
    }
}

@MainActor
struct ClipboardPollingTests {
    @Test func pollsFastRightAfterACopyThenSlows() {
        #expect(ClipboardMonitor.interval(sinceChange: 0) == ClipboardMonitor.activeInterval)
        #expect(ClipboardMonitor.interval(sinceChange: ClipboardMonitor.burst - 1) == ClipboardMonitor.activeInterval)
        #expect(ClipboardMonitor.interval(sinceChange: ClipboardMonitor.burst) == ClipboardMonitor.idleInterval)
        #expect(ClipboardMonitor.interval(sinceChange: .infinity) == ClipboardMonitor.idleInterval)
        #expect(ClipboardMonitor.idleInterval <= 1)
    }

    @Test func pauseStopsPollingAndResumeRestartsIt() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let monitor = ClipboardMonitor(store: ClipboardStore(dir: dir)) { HopConfig.Clipboard() }
        let polling = [ClipboardMonitor.activeInterval, ClipboardMonitor.idleInterval]
        monitor.start()
        #expect(monitor.isRunning)
        #expect(polling.contains(monitor.pollInterval ?? -1))
        monitor.isPaused = true
        #expect(monitor.isRunning)
        #expect(monitor.pollInterval == nil)
        monitor.isPaused = false
        #expect(polling.contains(monitor.pollInterval ?? -1))
        monitor.stop()
        #expect(monitor.pollInterval == nil)
        // Paused before starting: started, but no timer until resumed.
        monitor.isPaused = true
        monitor.start()
        #expect(monitor.pollInterval == nil)
        monitor.isPaused = false
        #expect(monitor.pollInterval != nil)
        monitor.stop()
    }
}

@MainActor
struct CalendarRefreshTests {
    @Test func launcherShowRefreshesOnlyStaleEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CalendarController.isStale(lastRefresh: .distantPast, now: now))
        #expect(!CalendarController.isStale(lastRefresh: now.addingTimeInterval(-30), now: now))
        #expect(CalendarController.isStale(lastRefresh: now.addingTimeInterval(-CalendarController.showRefreshAge), now: now))
        // The clock was set back.
        #expect(CalendarController.isStale(lastRefresh: now.addingTimeInterval(3600), now: now))
    }
}

@MainActor
struct IconCacheTests {
    @Test func purgeDropsRenderedIcons() throws {
        let cache = IconCache(watchMemoryPressure: false)
        let icon = ItemIcon.tile("calendar", .systemBlue)
        let first = try #require(cache.image(for: icon))
        #expect(cache.image(for: icon) === first)
        cache.purge()
        #expect(cache.image(for: icon) !== first)
    }
}

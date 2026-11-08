import AppKit
import os

/// Every open shelf, how they open (a shake or the modifier while dragging, hotkeys,
/// commands, `hop shelf`) and the recently closed ones you can bring back.
final class ShelfController {
    /// `hop shelf <paths>` posts this with the paths in `userInfo["paths"]`.
    static let addNotification = Notification.Name(AppPaths.bundleID + ".shelf.add")
    private static let recentLimit = 10

    private let settings: AppSettings
    private var config: HopConfig.Shelf { settings.data.shelf }
    private let watcher = DragWatcher()
    private(set) var shelves: [Shelf] = []
    /// Closed shelves' contents, newest first.
    private(set) var recent: [[ShelfItem]] = []
    private let store = JSONStore<[[ShelfItem]]>(url: AppPaths.file("shelves.json"))
    private var dropCheck: Timer?
    private var cliObserver: NSObjectProtocol?
    /// A shelf opened or closed (root commands depend on it).
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        recent = store.load() ?? []
        watcher.onActivate = { [weak self] point in self?.dragActivated(at: point) }
        watcher.onDragEnd = { [weak self] in self?.dragEnded() }
        cliObserver = DistributedNotificationCenter.default().addObserver(forName: Self.addNotification, object: nil, queue: .main) { [weak self] note in
            let paths = (note.userInfo?["paths"] as? [String]) ?? []
            MainActor.assumeIsolated { self?.addFromCLI(paths) }
        }
        ShelfItem.pruneDrops(olderThan: 7, keeping: Set(recent.flatMap { $0.map(\.value) }))
    }

    /// Starts or stops watching drags to match the config.
    func apply(_ config: HopConfig.Shelf) {
        var c = DragWatcher.Config()
        c.shake = config.shake
        c.sensitivity = config.shakeSensitivity
        c.modifiers = DragWatcher.modifiers(config.modifier) ?? []
        c.ignoreApps = Set(config.ignoreApps)
        watcher.config = c
        if DragWatcher.modifiers(config.modifier) == nil {
            Log.app.error("shelf.modifier: unknown \(config.modifier, privacy: .public), modifier activation off")
        }
        let watch = config.enabled && (c.shake || !c.modifiers.isEmpty)
        if watch { watcher.start() } else { watcher.stop() }
        if !config.enabled { closeAll() }
    }

    // MARK: - Opening

    @discardableResult
    func newShelf(_ items: [ShelfItem] = [], at point: NSPoint? = nil) -> Shelf {
        let shelf = Shelf()
        shelf.keepAfterDragOut = { [weak self] in self?.config.keepAfterDragOut ?? false }
        shelf.onClose = { [weak self] in self?.closed($0) }
        shelf.add(items)
        shelves.append(shelf)
        shelf.show(at: point ?? staggered(NSEvent.mouseLocation))
        onChange?()
        return shelf
    }

    func newShelfFromClipboard() {
        let items = ShelfItem.items(from: .general)
        guard !items.isEmpty else {
            HUD.shared.show("Nothing on the clipboard for a shelf", symbol: "exclamationmark.triangle.fill")
            return
        }
        newShelf(items)
    }

    /// Brings back the most recently closed shelf, without the files that are gone.
    func reopenLast() {
        while let items = recent.first {
            recent.removeFirst()
            let alive = items.filter(\.exists)
            if !alive.isEmpty {
                save()
                newShelf(alive)
                return
            }
        }
        save()
        HUD.shared.show("No closed shelf to reopen", symbol: "exclamationmark.triangle.fill")
    }

    func closeAll() {
        for shelf in shelves { shelf.close() }
    }

    /// A new shelf sits a little offset from one already at that spot.
    private func staggered(_ point: NSPoint) -> NSPoint {
        var p = point
        while shelves.contains(where: { $0.panel.isVisible && abs($0.panel.frame.midX - p.x) < 12 && abs($0.panel.frame.midY - p.y) < 12 }) {
            p.x += 24
            p.y -= 24
        }
        return p
    }

    private func addFromCLI(_ paths: [String]) {
        let items = paths.map { ShelfItem.file($0) }.filter(\.exists)
        guard !items.isEmpty else { return }
        // Onto the newest visible shelf, like dropping onto it; otherwise a new one.
        if let shelf = shelves.last(where: { $0.panel.isVisible }) {
            shelf.add(items)
            shelf.panel.orderFrontRegardless()
        } else {
            newShelf(items)
        }
    }

    // MARK: - Drags

    private func dragActivated(at point: NSPoint) {
        guard config.enabled else { return }
        // A shelf already waiting for this drag, or one under the pointer, is enough.
        if shelves.contains(where: { $0.awaitingDrop && $0.panel.isVisible }) { return }
        if shelves.contains(where: { $0.panel.isVisible && $0.panel.frame.contains(point) }) { return }
        let shelf = newShelf(at: point)
        shelf.awaitingDrop = true
        startDropCheck()
    }

    /// An empty shelf opened for a drag closes once that drag ends elsewhere.
    private func dragEnded() {
        // The drop reaches the shelf after the mouse-up; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.closeUnused() }
    }

    private func closeUnused() {
        for shelf in shelves where shelf.awaitingDrop && shelf.isEmpty && !shelf.pinned {
            shelf.close()
        }
        if !shelves.contains(where: \.awaitingDrop) {
            dropCheck?.invalidate()
            dropCheck = nil
        }
    }

    /// Mouse-ups during another app's drag do not always reach a global monitor, so
    /// also notice the button being released.
    private func startDropCheck() {
        guard dropCheck == nil else { return }
        dropCheck = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.dropCheck?.invalidate()
                self.dropCheck = nil
                self.dragEnded()
            }
        }
    }

    // MARK: - Recent

    private func closed(_ shelf: Shelf) {
        shelves.removeAll { $0 === shelf }
        defer { onChange?() }
        guard !shelf.isEmpty else { return }
        recent.removeAll { $0 == shelf.items }
        recent.insert(shelf.items, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        save()
    }

    private func save() { store.save(recent) }

    /// Open shelves go to the recent list so "Reopen Shelf" finds them after a restart.
    func saveNow() {
        for shelf in shelves where !shelf.isEmpty {
            recent.removeAll { $0 == shelf.items }
            recent.insert(shelf.items, at: 0)
        }
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        save()
    }
}

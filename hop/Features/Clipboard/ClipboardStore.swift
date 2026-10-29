import AppKit
import CryptoKit
import ImageIO
import os

/// Clipboard history on disk: `index.json` plus image / rich-text payload files, all
/// readable by the user only (folder 0700, files 0600). Newest first.
final class ClipboardStore {
    let dir: URL
    private(set) var items: [ClipboardItem] = []
    var onChange: (() -> Void)?
    private var saveTask: Task<Void, Never>?

    private var indexURL: URL { dir.appending(path: "index.json") }

    init(dir: URL = AppPaths.file("Clipboard")) {
        self.dir = dir
    }

    // MARK: Load and save

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            items = try decoder.decode([ClipboardItem].self, from: data)
            removeOrphanFiles()
        } catch {
            // Never overwrite a history we could not read: set it aside, keep the payloads.
            let aside = dir.appending(path: "index.json.bad")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            Log.app.error("clipboard: unreadable history moved to index.json.bad: \(error.localizedDescription, privacy: .public)")
            items = []
        }
    }

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try ensureDir()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            Log.app.error("clipboard: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Changes

    /// Adds a capture, or moves an identical earlier one to the top.
    func add(_ item: ClipboardItem, image: Data? = nil, rtf: Data? = nil) {
        if let i = items.firstIndex(where: { $0.hash == item.hash }) {
            var existing = items.remove(at: i)
            existing.lastCopied = item.lastCopied
            existing.timesCopied += 1
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            existing.sourceName = item.sourceName ?? existing.sourceName
            items.insert(existing, at: 0)
        } else {
            var new = item
            do {
                try ensureDir()
                if let image {
                    let name = "\(item.id).png"
                    try write(image, name)
                    new.imageFile = name
                }
                if let rtf {
                    let name = "\(item.id).rtf"
                    try write(rtf, name)
                    new.rtfFile = name
                }
            } catch {
                Log.app.error("clipboard: payload write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            items.insert(new, at: 0)
        }
        changed()
    }

    /// Marks an entry as just used (pasted or copied from the history).
    func touch(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.lastCopied = Date()
        item.timesCopied += 1
        items.insert(item, at: 0)
        changed()
    }

    func togglePin(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        changed()
    }

    func delete(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(of: items.remove(at: i))
        changed()
    }

    /// Deletes everything except pinned entries; returns how many went.
    @discardableResult
    func clear() -> Int {
        let gone = items.filter { !$0.pinned }
        gone.forEach(removeFiles)
        items.removeAll { !$0.pinned }
        changed()
        return gone.count
    }

    /// Drops unpinned entries older than `keepDays` (-1 keeps forever) and beyond `maxItems`.
    func prune(keepDays: Int, maxItems: Int, now: Date = Date()) {
        var gone: [ClipboardItem] = []
        if keepDays >= 0 {
            let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
            gone += items.filter { !$0.pinned && $0.lastCopied < cutoff }
            items.removeAll { !$0.pinned && $0.lastCopied < cutoff }
        }
        let unpinned = items.filter { !$0.pinned }
        if maxItems >= 0 && unpinned.count > maxItems {
            let drop = Set(unpinned.suffix(unpinned.count - maxItems).map(\.id))
            gone += items.filter { drop.contains($0.id) }
            items.removeAll { drop.contains($0.id) }
        }
        guard !gone.isEmpty else { return }
        gone.forEach(removeFiles)
        changed()
    }

    private func changed() {
        onChange?()
        saveSoon()
    }

    // MARK: Payloads

    func imageURL(_ item: ClipboardItem) -> URL? { item.imageFile.map { dir.appending(path: $0) } }

    func imageData(_ item: ClipboardItem) -> Data? { imageURL(item).flatMap { try? Data(contentsOf: $0) } }

    func rtfData(_ item: ClipboardItem) -> Data? { item.rtfFile.flatMap { try? Data(contentsOf: dir.appending(path: $0)) } }

    private func write(_ data: Data, _ name: String) throws {
        let url = dir.appending(path: name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeFiles(of item: ClipboardItem) {
        for name in [item.imageFile, item.rtfFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    private func removeOrphanFiles() {
        // A set-aside history still points at its payloads.
        guard !FileManager.default.fileExists(atPath: dir.appending(path: "index.json.bad").path) else { return }
        let used = Set(items.flatMap { [$0.imageFile, $0.rtfFile].compactMap { $0 } } + ["index.json", "index.json.bad"])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    // MARK: Fingerprints

    nonisolated static func fingerprint(_ kind: ClipboardKind, _ parts: [Data]) -> String {
        var h = SHA256()
        h.update(data: Data(kind.rawValue.utf8))
        for p in parts { h.update(data: p) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Watches the general pasteboard and records what gets copied. macOS has no change
/// notification, so it polls the change count: twice a second for a while after a copy
/// (copies come in bursts), once a second otherwise, and not at all while the screen is
/// locked or the Mac asleep. Switching apps checks at once, so a copy is still credited
/// to the app it came from, and hop checks before showing the history.
final class ClipboardMonitor {
    private let store: ClipboardStore
    private let config: () -> HopConfig.Clipboard
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var lastChange = NSPasteboard.general.changeCount
    private var lastChangeSeen = Date.distantPast
    /// The app in front before the latest switch; a copy noticed on the switch came from it.
    private weak var lastFront: NSRunningApplication?
    private var running = false

    nonisolated static let activeInterval: TimeInterval = 0.5
    nonisolated static let idleInterval: TimeInterval = 1
    /// How long after a copy polling stays at `activeInterval`.
    nonisolated static let burst: TimeInterval = 30

    /// Pasteboard markers from apps that ask clipboard managers to look away
    /// (nspasteboard.org, 1Password, KeeWeb, TypeIt4Me, Keyboard Maestro).
    static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType", "com.agilebits.onepassword", "net.antelle.keeweb",
        "com.typeit4me.clipping", "Pasteboard generator type",
    ]

    init(store: ClipboardStore, config: @escaping () -> HopConfig.Clipboard) {
        self.store = store
        self.config = config
    }

    /// Started (from config); polling may still be paused.
    var isRunning: Bool { running }
    /// Locked screen or sleep: no polling; resuming catches up on what was copied meanwhile.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue, running else { return }
            if isPaused {
                stopTimer()
            } else {
                check()
                schedule()
            }
        }
    }
    /// The current polling period, nil while not polling.
    var pollInterval: TimeInterval? { timer?.timeInterval }

    nonisolated static func interval(sinceChange: TimeInterval) -> TimeInterval {
        sinceChange < burst ? activeInterval : idleInterval
    }

    func start() {
        guard !running else { return }
        running = true
        lastChange = NSPasteboard.general.changeCount
        lastFront = NSWorkspace.shared.frontmostApplication
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
        if !isPaused { schedule() }
    }

    func stop() {
        running = false
        stopTimer()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }

    /// hop wrote the pasteboard itself (paste from history): don't record it again.
    func ignoreCurrentChange() { lastChange = NSPasteboard.general.changeCount }

    /// Records a copy made since the last poll, e.g. right before the history is shown.
    func check() {
        guard running, !isPaused else { return }
        poll(source: NSWorkspace.shared.frontmostApplication)
    }

    private func activated(_ app: NSRunningApplication?) {
        if !isPaused { poll(source: lastFront) }
        lastFront = app
    }

    private func schedule(now: Date = Date()) {
        let wanted = Self.interval(sinceChange: now.timeIntervalSince(lastChangeSeen))
        guard timer?.timeInterval != wanted else { return }
        stopTimer()
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = wanted / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        poll(source: NSWorkspace.shared.frontmostApplication)
        // Back to the slow period once a burst of copies is over.
        schedule()
    }

    private func poll(source: NSRunningApplication?) {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        lastChangeSeen = Date()
        capture(pb, from: source)
        if timer != nil { schedule() }
    }

    private func capture(_ pb: NSPasteboard, from front: NSRunningApplication?) {
        let cfg = config()
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skipTypes) else { return }
        if let id = front?.bundleIdentifier, cfg.ignoreApps.contains(id) { return }
        let source = (front?.bundleIdentifier, front?.localizedName)

        // Files
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let item = ClipboardItem(kind: .file, text: paths.joined(separator: "\n"), filePaths: paths,
                                     sourceBundleID: source.0, sourceName: source.1,
                                     hash: ClipboardStore.fingerprint(.file, paths.map { Data($0.utf8) }))
            store.add(item)
            return
        }

        let string = pb.string(forType: .string)
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Images (unless the copy is really text that happens to carry a picture)
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if cfg.images, trimmed.isEmpty || ClipboardClassifier.isLink(trimmed),
           let raw = imageTypes.lazy.compactMap({ pb.data(forType: $0) }).first,
           raw.count <= cfg.maxImageMB * 1_048_576,
           let (png, w, h) = Self.png(raw) {
            let item = ClipboardItem(kind: .image, imageWidth: w, imageHeight: h, bytes: png.count,
                                     sourceBundleID: source.0, sourceName: source.1,
                                     hash: ClipboardStore.fingerprint(.image, [png]))
            store.add(item, image: png)
            return
        }

        // Text
        guard let string, !trimmed.isEmpty, string.utf8.count <= 2_000_000 else { return }
        let kind = ClipboardClassifier.kind(of: string)
        let rtf = kind == .text ? pb.data(forType: .rtf).flatMap { $0.count <= 1_048_576 ? $0 : nil } : nil
        let item = ClipboardItem(kind: kind, text: kind == .text ? string : trimmed, bytes: string.utf8.count,
                                 sourceBundleID: source.0, sourceName: source.1,
                                 hash: ClipboardStore.fingerprint(kind, [Data((kind == .text ? string : trimmed).utf8)]))
        store.add(item, rtf: rtf)
    }

    /// PNG bytes and pixel size of pasteboard image data (screenshots arrive as TIFF).
    nonisolated static func png(_ data: Data) -> (Data, Int, Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, w, h) }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, w, h)
    }
}

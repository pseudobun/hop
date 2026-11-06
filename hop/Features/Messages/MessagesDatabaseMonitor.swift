import Foundation

/// Calls `onChange` when Messages writes to `chat.db`, at most once per `delay`.
///
/// Event driven, no polling: dispatch sources on `chat.db`, its WAL and the Messages folder
/// (the WAL comes and goes with Messages' connection). Messages writes the WAL for far more
/// than new messages (read receipts, typing, iCloud sync), so a burst of events is coalesced
/// into one call, `delay` after the first.
final class MessagesDatabaseMonitor {
    private let delay: Duration
    private let onChange: () -> Void
    private var sources: [String: (source: DispatchSourceFileSystemObject, inode: UInt64)] = [:]
    private var active = false
    /// Bumped on stop, so a pending call is dropped.
    private var generation = 0
    private var scheduled = false

    private static var folder: URL { MessageCodes.database.deletingLastPathComponent() }

    init(delay: Duration = .milliseconds(700), onChange: @escaping () -> Void) {
        self.delay = delay
        self.onChange = onChange
    }

    func start() {
        guard !active else { return }
        active = true
        rearm()
    }

    func stop() {
        for entry in sources.values { entry.source.cancel() }
        sources = [:]
        active = false
        generation += 1
        scheduled = false
    }

    /// (Re)opens a source for each path that exists and isn't watched yet, or was replaced.
    /// Call after reading the database: the WAL may have been recreated meanwhile.
    func rearm() {
        guard active else { return }
        let db = MessageCodes.database.path
        let paths: [(String, DispatchSource.FileSystemEvent)] = [
            (Self.folder.path, [.write]), // entries added or removed: the WAL reappearing
            (db, [.write, .extend]),
            (db + "-wal", [.write, .extend, .delete, .rename]),
        ]
        for (path, mask) in paths {
            var st = stat()
            guard stat(path, &st) == 0 else {
                sources.removeValue(forKey: path)?.source.cancel()
                continue
            }
            let inode = UInt64(st.st_ino)
            if sources[path]?.inode == inode { continue }
            sources.removeValue(forKey: path)?.source.cancel()
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources[path] = (s, inode)
        }
    }

    /// Asks for one more call, coalesced like a file event (e.g. a write landed mid-read).
    func changed() {
        guard active, !scheduled else { return }
        scheduled = true
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            guard let self, gen == generation else { return }
            scheduled = false
            onChange()
        }
    }
}

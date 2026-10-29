import AppKit

/// Announces a one-time code as it arrives in Messages, ready to paste.
///
/// Event driven, no polling: dispatch sources on `chat.db`, its WAL and the Messages folder
/// (the WAL comes and goes with Messages' connection). Messages writes the WAL for far more
/// than new messages (read receipts, typing, iCloud sync), so events are coalesced into at most
/// one check per `delay`, and a check is `SELECT MAX(ROWID)` until a row newer than the last
/// one seen shows up. Off, or without Full Disk Access, nothing is watched at all.
final class MessageCodeWatcher {
    private var config = HopConfig.Messages()
    private var sources: [String: (source: DispatchSourceFileSystemObject, inode: UInt64)] = [:]
    private var active = false
    /// Bumped on stop, so a check still in flight drops its result.
    private var generation = 0
    private var lastRowID: Int64?
    private var scheduled = false
    private var checking = false
    private var dirty = false
    private let delay: Duration = .milliseconds(700)

    private static var folder: URL { MessageCodes.database.deletingLastPathComponent() }

    func apply(_ config: HopConfig.Messages) {
        self.config = config
        // Granting Full Disk Access takes a relaunch anyway, so checking once here is enough.
        guard config.enabled, config.notify || config.autoCopy,
              FileManager.default.isReadableFile(atPath: MessageCodes.database.path) else {
            stop()
            return
        }
        guard !active else { return }
        active = true
        arm()
        check() // the baseline: codes already in the database are not news
    }

    func stop() {
        for entry in sources.values { entry.source.cancel() }
        sources = [:]
        active = false
        generation += 1
        lastRowID = nil
        scheduled = false
        dirty = false
    }

    // MARK: - Watching

    /// (Re)opens a source for each path that exists and isn't watched yet, or was replaced.
    private func arm() {
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

    /// Coalesces a burst of writes into one check, `delay` after the first.
    private func changed() {
        guard active, !scheduled else { return }
        scheduled = true
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            guard let self, gen == generation else { return }
            scheduled = false
            check()
        }
    }

    private func check() {
        guard active else { return }
        guard !checking else {
            dirty = true
            return
        }
        checking = true
        let gen = generation
        let after = lastRowID
        Task {
            let result = await MessageCodes.newer(than: after)
            checking = false
            guard gen == generation else { return }
            arm()
            switch result {
            case .success(let batch):
                // Taken as is even when lower: a rebuilt database starts counting again.
                lastRowID = batch.lastRowID
                let now = Date()
                if after != nil, let code = batch.codes.first(where: { MessageCodes.isFresh($0, now: now) }) {
                    announce(code)
                }
            case .failure(.noAccess):
                stop() // Full Disk Access was taken away
                return
            case .failure:
                break // busy or mid-checkpoint; the next write retries
            }
            if dirty {
                dirty = false
                changed()
            }
        }
    }

    // MARK: - Announcing

    private func announce(_ code: MessageCode) {
        if config.autoCopy {
            Pasteboard.copy(code.code, concealed: true)
            Pasteboard.clearLater(after: 120)
        }
        guard config.notify else { return }
        HUD.shared.show(Self.message(for: code, pasteHotkey: config.pasteHotkey, copied: config.autoCopy),
                        symbol: "message.fill", tone: .success, seconds: 5)
    }

    /// `482913 · Revolut — ⌥⌘V to paste`.
    nonisolated static func message(for code: MessageCode, pasteHotkey: String, copied: Bool) -> String {
        var text = code.sender.isEmpty ? code.code : "\(code.code) · \(code.sender)"
        if let keys = HotkeySpec.glyphs(pasteHotkey) {
            text += " — \(keys) to paste"
        } else if copied {
            text += " — copied"
        }
        return text
    }
}

nonisolated extension HotkeySpec {
    /// "alt+cmd+v" as ⌥⌘V, modifiers in the menu order; nil when it doesn't parse.
    static func glyphs(_ text: String) -> String? {
        guard parse(text) != nil else { return nil }
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        let mods = Set(parts.dropLast().flatMap { m -> [String] in
            switch m {
            case "cmd", "command", "⌘": ["⌘"]
            case "ctrl", "control", "⌃": ["⌃"]
            case "alt", "opt", "option", "⌥": ["⌥"]
            case "shift", "⇧": ["⇧"]
            case "hyper": ["⌃", "⌥", "⇧", "⌘"]
            default: []
            }
        })
        let key = parts.last ?? ""
        let names = ["space": "Space", "return": "↩", "enter": "↩", "tab": "⇥", "escape": "⎋"]
        return ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains).joined() + (names[key] ?? key.uppercased())
    }
}

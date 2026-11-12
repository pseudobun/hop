import AppKit

/// Announces a one-time code as it arrives in Messages, ready to paste.
///
/// `MessagesDatabaseMonitor` reports writes; a check is `SELECT MAX(ROWID)` until a row newer
/// than the last one seen shows up. Off, or without Full Disk Access, nothing is watched at all.
final class MessageCodeWatcher {
    private var config = HopConfig.Messages()
    private lazy var monitor = MessagesDatabaseMonitor { [weak self] in self?.check() }
    private var active = false
    /// Bumped on stop, so a check still in flight drops its result.
    private var generation = 0
    private var lastRowID: Int64?
    private var checking = false
    private var dirty = false

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
        monitor.start()
        check() // the baseline: codes already in the database are not news
    }

    func stop() {
        monitor.stop()
        active = false
        generation += 1
        lastRowID = nil
        dirty = false
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
            monitor.rearm()
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
                monitor.changed()
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

import AppKit
import CoreGraphics

nonisolated enum PasteboardType {
    /// nspasteboard.org markers: clipboard managers skip these.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

enum Pasteboard {
    static func copy(_ text: String, concealed: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed { pb.setString("", forType: PasteboardType.concealed) }
    }

    /// Clears the clipboard after `seconds` if nothing else was copied meanwhile.
    static func clearLater(after seconds: Double) {
        let count = NSPasteboard.general.changeCount
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    /// Puts `text` on the pasteboard, sends ⌘V to the frontmost app and restores
    /// the previous clipboard. Needs Accessibility; returns false without it.
    @discardableResult
    static func paste(_ text: String, concealed: Bool) async -> Bool {
        guard AXIsProcessTrusted() else {
            copy(text, concealed: concealed)
            return false
        }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: PasteboardType.transient)
        if concealed { pb.setString("", forType: PasteboardType.concealed) }
        let ours = pb.changeCount
        // A launcher fading out still has the keyboard: ⌘V would land in it.
        Motion.finishExits()

        try? await Task.sleep(for: .milliseconds(60))
        postCommandV()
        try? await Task.sleep(for: .milliseconds(500))
        if pb.changeCount == ours { restore(saved, to: pb) }
        return true
    }

    static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { dict in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        pb.writeObjects(restored)
    }
}

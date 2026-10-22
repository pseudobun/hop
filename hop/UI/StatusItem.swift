import AppKit

/// Menu bar bunny: a way in when ⌘Space is still taken, plus Settings and Quit.
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onOpen: () -> Void
    private let onSettings: () -> Void

    init(onOpen: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onSettings = onSettings
        super.init()
        let image = NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "hop")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Open hop", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func open() { onOpen() }
    @objc private func settings() { onSettings() }
}

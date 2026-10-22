import AppKit

/// Menu bar bunny: a way in when the hotkey is taken, plus Config and Quit.
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onOpen: () -> Void
    private let onConfig: () -> Void

    init(onOpen: @escaping () -> Void, onConfig: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onConfig = onConfig
        super.init()
        let image = NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "hop")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Open hop", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config…", action: #selector(config), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func open() { onOpen() }
    @objc private func config() { onConfig() }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

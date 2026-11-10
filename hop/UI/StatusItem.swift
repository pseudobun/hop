import AppKit

/// Menu bar bunny: a way in when the hotkey is taken, plus Settings, Config and Quit.
final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onOpen: () -> Void
    private let onNotes: () -> Void
    private let onClipboard: () -> Void
    private let onSettings: () -> Void
    private let onConfig: () -> Void

    init(onOpen: @escaping () -> Void, onNotes: @escaping () -> Void, onClipboard: @escaping () -> Void,
         onSettings: @escaping () -> Void, onConfig: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onNotes = onNotes
        self.onClipboard = onClipboard
        self.onSettings = onSettings
        self.onConfig = onConfig
        super.init()
        let image = Self.bunny() ?? NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "hop")
        image?.isTemplate = true
        image?.accessibilityDescription = "hop"
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Open hop", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Notes", action: #selector(notes), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clipboard History", action: #selector(clipboardHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Config File…", action: #selector(config), keyEquivalent: "").target = self
        if Updater.shared.isAvailable {
            updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem?.target = self
            menu.delegate = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func open() { onOpen() }
    @objc private func notes() { onNotes() }
    @objc private func clipboardHistory() { onClipboard() }
    @objc private func openSettings() { onSettings() }
    @objc private func config() { onConfig() }
    @objc private func checkForUpdates() { Updater.shared.checkNow() }

    private var updateItem: NSMenuItem?

    func menuNeedsUpdate(_ menu: NSMenu) { updateItem?.isEnabled = Updater.shared.state != .checking }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    /// The launcher's bunny logo as an 18 pt template image: a solid silhouette with the
    /// dark eyes, nose and mouth cut out. Drawing the SVG three times closes the
    /// anti-aliased seams between its polygons.
    static func bunny(points: Int = 18) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "bunny", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in [1, 2] {
            let px = points * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep), let p = rep.bitmapData
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for _ in 0..<3 { svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) }
            NSGraphicsContext.restoreGraphicsState()
            for i in stride(from: 0, to: rep.bytesPerRow * px, by: 4) where p[i + 3] > 0 {
                let alpha = Double(p[i + 3]) / 255
                let lightness = (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 765 / alpha
                let keep = min(max((lightness - 0.3) / 0.4, 0), 1)
                (p[i], p[i + 1], p[i + 2], p[i + 3]) = (0, 0, 0, UInt8((alpha * keep * 255).rounded()))
            }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }
}

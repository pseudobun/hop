import AppKit

/// Borderless, non-activating floating panel: the app never activates, so the
/// previously focused app stays frontmost for paste actions.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 750, height: 475)

    /// Sees every keyDown before the field editor; return true to consume.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }

    /// Centre horizontally on the screen under the mouse, upper third vertically.
    func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - frame.width / 2
        let y = visible.minY + visible.height * 0.62 - frame.height / 2
        setFrameOrigin(NSPoint(x: x.rounded(), y: min(y, visible.maxY - frame.height).rounded()))
    }
}

/// Short confirmation shown after an action, e.g. "Copied 8".
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let glass = panel.contentView as? NSGlassEffectView,
              let stack = glass.contentView as? NSStackView,
              let image = stack.arrangedSubviews.first as? NSImageView,
              let label = stack.arrangedSubviews.last as? NSTextField
        else { return }
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = text
        let size = stack.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(size.width + 32, 120), height: 40)
        panel.setContentSize(frame.size)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (v.midX - frame.width / 2).rounded(), y: v.minY + v.height * 0.12))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        let image = NSImageView()
        image.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [image, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        glass.contentView = stack
        p.contentView = glass
        return p
    }
}

import AppKit

/// Non-activating floating panel: the app never activates, so the previously
/// focused app stays frontmost for paste actions. Titled + full-size content (like
/// Raycast) so the window server draws a rounded frame and shadow; a borderless
/// window gets a rectangular one around the rounded glass.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 750, height: 475)

    /// Sees every keyDown before the field editor; return true to consume.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isMovable = false
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

extension NSWindow {
    /// The frame's corner radius (16 on macOS 26), so the glass matches it exactly.
    var frameCornerRadius: CGFloat {
        let sel = NSSelectorFromString("_effectiveCornerRadius")
        guard responds(to: sel), let m = class_getInstanceMethod(type(of: self), sel) else { return 16 }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
        let r = unsafeBitCast(method_getImplementation(m), to: Getter.self)(self, sel)
        return r > 0 ? r : 16
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
        image.contentTintColor = symbol.contains("checkmark") ? Theme.good : Theme.warn
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
        p.hasShadow = false // a shadow adds a rectangular frame around borderless glass
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.appearance = Theme.darkAppearance
        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        glass.tintColor = Theme.background.withAlphaComponent(0.78)
        let image = NSImageView()
        image.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "")
        label.font = Theme.sans(13, 500)
        label.textColor = Theme.foreground
        let stack = NSStackView(views: [image, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        glass.contentView = stack
        p.contentView = glass
        return p
    }
}

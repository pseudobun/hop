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
}

extension NSWindow {
    /// Centre horizontally on the screen under the mouse, upper third vertically; a window
    /// bigger than that screen shrinks to fit.
    func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: min(frame.width, visible.width - 80), height: min(frame.height, visible.height - 80))
        let x = visible.midX - size.width / 2
        let y = visible.minY + visible.height * 0.62 - size.height / 2
        setFrame(NSRect(x: x.rounded(), y: min(y, visible.maxY - size.height).rounded(), width: size.width, height: size.height),
                 display: false)
    }

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
    /// The theme the panel was built in: a HUD after a theme switch is built again.
    private var panelTheme: Theme.Name?

    enum Tone { case success, warning, failure }

    /// Red cross: something did not work.
    func fail(_ text: String) { show(text, symbol: "xmark.octagon.fill", tone: .failure) }

    /// Amber triangle: nothing went wrong, but nothing happened either.
    func warn(_ text: String) { show(text, symbol: "exclamationmark.triangle.fill", tone: .warning) }

    /// One line of plain text: control and bidi-override characters dropped (command output can
    /// carry them), whitespace collapsed, at most 160 characters.
    nonisolated static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if CharacterSet.newlines.contains(s) || s == "\t" { scalars.append(" "); continue }
            if s.properties.generalCategory == .control || isDirectional(s.value) { continue }
            scalars.append(s)
        }
        var out = String(scalars)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.count > 160 ? String(out.prefix(159)) + "…" : out
    }

    /// LRM, RLM, the embeddings and overrides, and the isolates.
    nonisolated private static func isDirectional(_ v: UInt32) -> Bool {
        v == 0x200E || v == 0x200F || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    /// Without a tone, a checkmark is a success and any other symbol a notice.
    /// `seconds` overrides how long it stays up.
    func show(_ text: String, symbol: String = "checkmark.circle.fill", tone: Tone? = nil, seconds: Double? = nil) {
        if panelTheme != Theme.variant { self.panel?.orderOut(nil); self.panel = nil }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panelTheme = Theme.variant
        guard let glass = panel.contentView as? NSGlassEffectView,
              let stack = glass.contentView?.subviews.first as? NSStackView,
              let image = stack.arrangedSubviews.first as? NSImageView,
              let label = stack.arrangedSubviews.last as? NSTextField
        else { return }
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        switch tone ?? (symbol.contains("checkmark") ? .success : .warning) {
        case .success: image.contentTintColor = Theme.good
        case .warning: image.contentTintColor = Theme.warn
        case .failure: image.contentTintColor = Theme.destructive
        }
        label.stringValue = Self.sanitized(text)
        let size = stack.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(size.width + 40, 140), height: 40)
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
            // Long enough to read: 2.2 s, plus a little for longer messages.
            let ms = seconds.map { Int($0 * 1000) } ?? min(4000, 2200 + max(0, text.count - 30) * 40)
            try? await Task.sleep(for: .milliseconds(ms))
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
        p.appearance = Theme.appearance
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
        // Centred in the glass; a stack filling it would hug its leading edge.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        glass.contentView = container
        p.contentView = glass
        return p
    }
}

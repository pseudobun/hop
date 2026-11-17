import AppKit

/// Non-activating floating panel: the app never activates, so the previously
/// focused app stays frontmost for paste actions. Borderless, with room around the glass for
/// hop's own shadow (`ShadowedSurface`): the window server's shadow (and its dark rim) stays
/// at full size while the content grows in, so it showed up first, as a black edge.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 750, height: 475)
    /// Room on each side of the glass for the shadow.
    static let margin = ShadowedSurface.margin

    /// Sees every keyDown before the field editor; return true to consume.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        let m = Self.margin
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size.width + 2 * m, height: Self.size.height + 2 * m),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isMovable = false
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    /// The glass's corner radius: as a titled window's frame on macOS 26.
    static let cornerRadius: CGFloat = 16

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

extension NSWindow {
    /// Centre horizontally on the screen under the mouse, upper third vertically; a window
    /// bigger than that screen shrinks to fit. `margin`: transparent room around the visible
    /// part (a drawn shadow), left out of the fit and the placement.
    func positionOnMouseScreen(margin: CGFloat = 0) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: min(frame.width - 2 * margin, visible.width - 80), height: min(frame.height - 2 * margin, visible.height - 80))
        let x = visible.midX - size.width / 2
        let y = min(visible.minY + visible.height * 0.62 - size.height / 2, visible.maxY - size.height)
        setFrame(NSRect(x: x.rounded() - margin, y: y.rounded() - margin, width: size.width + 2 * margin, height: size.height + 2 * margin),
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
    /// The theme (and custom-theme revision) the panel was built in: a HUD after a theme
    /// switch or an edit to the custom theme in use is built again.
    private var panelTheme: (name: Theme.Name, revision: Int, glass: String)?

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
        if panelTheme?.name != Theme.variant || panelTheme?.revision != Theme.revision || panelTheme?.glass != Glass.current {
            self.panel?.orderOut(nil)
            self.panel = nil
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panelTheme = (Theme.variant, Theme.revision, Glass.current)
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
        // Up already: stays; fading out: comes back from where it is.
        Motion.present(panel, duration: 0.18)
        hideTask?.cancel()
        hideTask = Task {
            // Long enough to read: 2.2 s, plus a little for longer messages.
            let ms = seconds.map { Int($0 * 1000) } ?? min(4000, 2200 + max(0, text.count - 30) * 40)
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled else { return }
            Motion.dismiss(panel, duration: 0.2)
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
        glass.style = Glass.style
        glass.tintColor = Glass.hudTint
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

/// A window's content view that holds its glass inset by `margin` and draws a soft shadow
/// around it (`general.shadow`), only outside the glass so see-through glass stays clear.
/// Motion scales this view's layer, so the shadow grows in with the glass.
final class ShadowedSurface: NSView {
    static let margin: CGFloat = 36
    /// `general.shadow` as 0…1.
    nonisolated(unsafe) static var strength: CGFloat = 0.3

    static func configure(_ general: HopConfig.General) { strength = CGFloat(general.shadow) / 100 }

    let surface: NSView
    private let cornerRadius: CGFloat
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    /// A click outside the glass (on the shadow): the window would otherwise swallow it.
    var onOutsideClick: (() -> Void)?

    /// `size`: the whole view, margin included.
    init(_ surface: NSView, cornerRadius: CGFloat, size: NSSize) {
        self.surface = surface
        self.cornerRadius = cornerRadius
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        layer?.addSublayer(shadowLayer)
        surface.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        refreshShadow()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Takes `strength` (it may have changed in the config since the last show).
    func refreshShadow() {
        let s = Self.strength
        shadowLayer.isHidden = s <= 0
        // Wide and soft, as Spotlight's: the radius grows a little with the strength.
        shadowLayer.shadowOpacity = Float(min(1, s * 1.1))
        shadowLayer.shadowRadius = 10 + 14 * s
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        let glass = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let path = CGPath(roundedRect: glass, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        shadowLayer.shadowPath = path
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(path)
        shadowMask.frame = bounds
        shadowMask.path = mask
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if surface.frame.contains(local) { return super.hitTest(point) }
        return self
    }

    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
}

import AppKit

/// Blurs everything behind the launcher (`general.backgroundBlur`): a click-through window
/// covering the launcher's screen, just below it, holding the system's behind-window blur (as
/// Spotlight and Mission Control) and a dim (`general.backgroundDim`). It fades in and out with
/// the launcher.
///
/// The blur is set up once and only the window's alpha moves. Turning a window-server blur
/// radius on at each open (the first version) showed a bright frame on the display.
enum BackdropBlur {
    /// `general.backgroundBlur` / `general.backgroundDim` (0…1).
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var dim: CGFloat = 0.2

    static func configure(_ general: HopConfig.General) {
        enabled = general.backgroundBlur
        dim = CGFloat(general.backgroundDim) / 100
        guard enabled else {
            hide(animated: false)
            window = nil
            return
        }
        if let window { style(window) } else { prepare() }
    }

    private static var window: NSWindow?

    /// Covers `screen` and fades the blur in over `duration`, just below `above`.
    static func show(on screen: NSScreen?, below above: NSWindow, duration: TimeInterval) {
        guard enabled, let screen = screen ?? NSScreen.main else { return }
        let window = self.window ?? makeWindow(screen.frame)
        self.window = window
        window.level = NSWindow.Level(rawValue: above.level.rawValue - 1)
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        Motion.present(window, duration: duration)
    }

    /// Fades the blur out over `duration` and orders the window out.
    static func hide(animated: Bool = true, duration: TimeInterval = Motion.closeDuration) {
        guard let window, window.isVisible else { return }
        Motion.dismiss(window, duration: animated ? duration : 0)
    }

    /// Builds the window and orders it in once, invisibly, so the first open does not set up
    /// the blur while the user watches.
    private static func prepare() {
        guard let screen = NSScreen.main else { return }
        let w = makeWindow(screen.frame)
        window = w
        w.alphaValue = 0
        w.orderFrontRegardless()
        w.displayIfNeeded()
        CATransaction.flush()
        w.orderOut(nil)
        w.alphaValue = 1
    }

    private static func makeWindow(_ frame: NSRect) -> NSWindow {
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.wantsLayer = true
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.cgColor
        shade.frame = blur.bounds
        shade.autoresizingMask = [.width, .height]
        blur.addSubview(shade)
        w.contentView = blur
        style(w)
        return w
    }

    /// Takes the theme's light or dark look and `dim`.
    private static func style(_ window: NSWindow) {
        window.appearance = Theme.appearance
        window.contentView?.subviews.first?.layer?.opacity = Float(dim)
    }
}

import AppKit

/// Blurs everything behind the launcher (`general.backgroundBlur`): a click-through window
/// covering the launcher's screen, just below it, whose window-server background blur grows
/// in as the launcher opens and eases off as it closes.
///
/// The blur is the window server's own (`CGSSetWindowBackgroundBlurRadius`, as the system uses
/// for its menus), looked up at run time; without it the feature does nothing.
@MainActor
enum BackdropBlur {
    /// `general.backgroundBlur` / `general.backgroundBlurRadius`.
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var radius = 20

    static func configure(_ general: HopConfig.General) {
        enabled = general.backgroundBlur
        radius = general.backgroundBlurRadius
        if !enabled { hide(animated: false) }
    }

    private static var window: NSWindow?
    private static var animation: BlurAnimation?
    /// The radius on screen now.
    fileprivate static var current: Double = 0

    /// Covers `screen` and blurs it in over `duration`, just below `above`.
    static func show(on screen: NSScreen?, below above: NSWindow, duration: TimeInterval) {
        guard enabled, radius > 0, Blur.available, let screen = screen ?? NSScreen.main else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        window.level = NSWindow.Level(rawValue: above.level.rawValue - 1)
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        if !window.isVisible { current = 0; Blur.set(window, 0) }
        window.orderFrontRegardless()
        animate(to: Double(radius), duration: duration, curve: .entrance)
    }

    /// Eases the blur off over `duration` and orders the window out.
    static func hide(animated: Bool = true, duration: TimeInterval = Motion.closeDuration) {
        guard let window, window.isVisible else { return }
        guard animated, Motion.allowed, duration > 0 else {
            animation?.stop()
            animation = nil
            current = 0
            Blur.set(window, 0)
            window.orderOut(nil)
            return
        }
        animate(to: 0, duration: duration, curve: .exit) { window.orderOut(nil) }
    }

    private static func animate(to target: Double, duration: TimeInterval, curve: BlurAnimation.Curve, done: (() -> Void)? = nil) {
        guard let window else { return }
        animation?.stop()
        guard Motion.allowed, duration > 0 else {
            current = target
            Blur.set(window, target)
            animation = nil
            done?()
            return
        }
        let a = BlurAnimation(window: window, from: current, to: target, duration: duration, curve: curve)
        a.onFinish = { [weak a] in
            if animation === a { animation = nil }
            done?()
        }
        animation = a
        a.start()
    }

    private static func makeWindow() -> NSWindow {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        // Not fully clear: the window server leaves a window with nothing in it out of the blur.
        w.backgroundColor = NSColor.black.withAlphaComponent(0.002)
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        return w
    }
}

/// The window server's background blur, found at run time.
private enum Blur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let functions: (MainConnection, SetRadius)? = {
        let all = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let c = dlsym(all, "CGSMainConnectionID"), let s = dlsym(all, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(c, to: MainConnection.self), unsafeBitCast(s, to: SetRadius.self))
    }()

    static var available: Bool { functions != nil }

    static func set(_ window: NSWindow, _ radius: Double) {
        guard let (connection, setRadius) = functions, window.windowNumber > 0 else { return }
        _ = setRadius(connection(), Int32(window.windowNumber), Int32(radius.rounded()))
    }
}

/// Steps the blur radius once per display frame, as `WindowFade` does the alpha; a timer
/// finishes it should no frame come.
@MainActor
private final class BlurAnimation: NSObject {
    enum Curve {
        case entrance, exit
        var points: (Double, Double, Double, Double) {
            switch self {
            case .entrance: (0.25, 0.1, 0.25, 1)
            case .exit: (0.3, 0, 0.5, 1)
            }
        }
    }

    private let window: NSWindow
    private let from: Double
    private let to: Double
    private let duration: CFTimeInterval
    private let curve: Curve
    private var link: CADisplayLink?
    private var watchdog: Timer?
    private var startTime: CFTimeInterval?
    var onFinish: (() -> Void)?

    init(window: NSWindow, from: Double, to: Double, duration: CFTimeInterval, curve: Curve) {
        self.window = window
        self.from = from
        self.to = to
        self.duration = duration
        self.curve = curve
    }

    func start() {
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let watchdog = Timer(timeInterval: duration + 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    @objc private func step(_ link: CADisplayLink) {
        let start = startTime ?? link.timestamp
        startTime = start
        let t = min(1, (link.targetTimestamp - start) / duration)
        guard t < 1 else { finish(); return }
        set(from + (to - from) * Motion.bezier(curve.points, t))
    }

    private func set(_ radius: Double) {
        BackdropBlur.current = radius
        Blur.set(window, radius)
    }

    private func finish() {
        guard link != nil else { return }
        stop()
        set(to)
        onFinish?()
    }

    func stop() {
        link?.invalidate()
        link = nil
        watchdog?.invalidate()
        watchdog = nil
    }
}

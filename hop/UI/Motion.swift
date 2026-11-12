import AppKit
import QuartzCore

/// Small motion: window entrances and exits, view fades. Scale runs on the render server; a
/// window's alpha is stepped once per display frame from the frame it first appears in.
enum Motion {
    /// Off when the user asked macOS to reduce motion.
    static var allowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Fast start, long soft landing (as tip's workspace highlight).
    static let glideTiming = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    /// The scale a window grows from on the way in, and shrinks to on the way out.
    static let entranceScale: CGFloat = 0.965
    static let exitScale: CGFloat = 0.985

    /// Orders a window in as Spotlight does: it fades in while its content settles from slightly
    /// small to full size. A window still fading out comes back from where it is; one already up
    /// is just ordered front.
    ///
    /// The fade is the window's alpha, so the glass, the content and the window shadow fade
    /// together. AppKit's `animator().alphaValue` starts its clock when called, but the first
    /// frame reaches the screen only after the caller's layout and drawing (about 40 ms after a
    /// hotkey press): the fade then began at 20–40 % opacity and read as a pop. This one starts
    /// with the first display frame, so every step of it is seen.
    static func present(_ window: NSWindow, duration: TimeInterval = 0.2) {
        let returning = WindowFade.running(window)?.isExit == true
        if window.isVisible && !returning {
            window.orderFrontRegardless()
            return
        }
        WindowFade.running(window)?.cancel()
        let layer = window.contentView?.layer
        guard allowed else {
            layer?.removeAnimation(forKey: "exit")
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }
        if returning {
            settle(layer, from: currentScale(layer))
            WindowFade(window, to: 1, duration: duration * 0.6, curve: .entrance).start()
            return
        }
        window.alphaValue = 0
        window.orderFrontRegardless()
        // Added before this run-loop turn's commit, so it starts with the first frame.
        settle(layer, from: entranceScale)
        WindowFade(window, to: 1, duration: duration, curve: .entrance).start()
    }

    /// Fades a window out (shrinking it a little) and orders it out, then calls `done`.
    /// `present` during the fade brings it back; `finishExits` cuts it short.
    static func dismiss(_ window: NSWindow, duration: TimeInterval = 0.13, done: (() -> Void)? = nil) {
        guard window.isVisible, WindowFade.running(window)?.isExit != true else { return }
        WindowFade.running(window)?.cancel()
        let layer = window.contentView?.layer
        guard allowed else {
            window.orderOut(nil)
            window.alphaValue = 1
            done?()
            return
        }
        if let layer {
            layer.removeAnimation(forKey: "settle")
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: scaled(layer, currentScale(layer)))
            shrink.toValue = NSValue(caTransform3D: scaled(layer, exitScale))
            shrink.duration = duration
            shrink.timingFunction = WindowFade.Curve.exit.function
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "exit")
        }
        let fade = WindowFade(window, to: 0, duration: duration, curve: .exit)
        fade.onFinish = { [weak window] in
            guard let window else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            window.contentView?.layer?.removeAnimation(forKey: "exit")
            done?()
        }
        fade.start()
    }

    /// Whether `window` is fading out: still on screen, but as good as hidden.
    static func isLeaving(_ window: NSWindow) -> Bool { WindowFade.running(window)?.isExit == true }

    /// Orders out every window that is fading out, at once. Before a synthetic keystroke (⌘V)
    /// or a screen capture: a window on its way out still has the keyboard and is still on screen.
    static func finishExits() { WindowFade.finishExits() }

    /// Fades a layer-backed view in by its layer's opacity.
    static func fadeIn(_ view: NSView, duration: CFTimeInterval = 0.1) {
        guard allowed, let layer = view.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "fadeIn")
    }

    // MARK: - Scale

    /// A soft spring from `scale` to the layer's own size, on the render server.
    private static func settle(_ layer: CALayer?, from scale: CGFloat) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "exit")
        let spring = CASpringAnimation(perceptualDuration: 0.24, bounce: 0.08)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: scaled(layer, scale))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "settle")
    }

    /// Scales about the layer's centre; AppKit's layers keep their anchor at the corner.
    private static func scaled(_ layer: CALayer, _ s: CGFloat) -> CATransform3D {
        let b = layer.bounds
        let cx = b.width * (0.5 - layer.anchorPoint.x), cy = b.height * (0.5 - layer.anchorPoint.y)
        var t = CATransform3DMakeTranslation(-cx, -cy, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1))
        return CATransform3DConcat(t, CATransform3DMakeTranslation(cx, cy, 0))
    }

    /// The scale on screen now (mid-animation), 1 when none runs.
    private static func currentScale(_ layer: CALayer?) -> CGFloat {
        guard let layer, let p = layer.presentation() else { return 1 }
        return CGFloat(p.transform.m11)
    }
}

/// Steps one window's alpha toward a target once per display frame, timed from the first frame
/// it runs in (not from when it was asked for). A timer finishes it should no frame come (the
/// display asleep), so a window is never left invisible.
private final class WindowFade: NSObject {
    enum Curve {
        case entrance, exit

        /// In: CSS `ease`, so the first frames stay faint and the fade is seen. Out: an even
        /// ease-in-out, gone without lingering.
        var function: CAMediaTimingFunction {
            switch self {
            case .entrance: CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            case .exit: CAMediaTimingFunction(controlPoints: 0.3, 0, 0.5, 1)
            }
        }

        var points: (Double, Double, Double, Double) {
            switch self {
            case .entrance: (0.25, 0.1, 0.25, 1)
            case .exit: (0.3, 0, 0.5, 1)
            }
        }
    }

    private static var running: [ObjectIdentifier: WindowFade] = [:]

    static func running(_ window: NSWindow) -> WindowFade? { running[ObjectIdentifier(window)] }

    static func finishExits() {
        for fade in running.values where fade.isExit { fade.finish() }
    }

    /// Holds the window until the fade is done, so an exit always orders it out.
    private let window: NSWindow
    private let from: CGFloat
    private let to: CGFloat
    private let duration: CFTimeInterval
    private let curve: Curve
    private var link: CADisplayLink?
    private var watchdog: Timer?
    private var startTime: CFTimeInterval?
    var onFinish: (() -> Void)?
    var isExit: Bool { to < from }

    init(_ window: NSWindow, to: CGFloat, duration: CFTimeInterval, curve: Curve) {
        self.window = window
        from = window.alphaValue
        self.to = to
        self.duration = duration
        self.curve = curve
    }

    func start() {
        Self.running[ObjectIdentifier(window)] = self
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let watchdog = Timer(timeInterval: duration + 0.35, repeats: false) { [weak self] _ in self?.finish() }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    @objc private func step(_ link: CADisplayLink) {
        // Timed from the frame this first runs in; each step shows the value for the frame
        // being prepared, so the first one is already a little above the start.
        let start = startTime ?? link.timestamp
        startTime = start
        let t = min(1, (link.targetTimestamp - start) / duration)
        guard t < 1 else { finish(); return }
        window.alphaValue = from + (to - from) * CGFloat(Self.solve(curve.points, t))
    }

    /// Ends it now at the target, as if it had run its course.
    func finish() {
        guard Self.running[ObjectIdentifier(window)] === self else { return }
        stop()
        window.alphaValue = to
        onFinish?()
    }

    /// Stops where it is; whoever cancels sets what comes next.
    func cancel() {
        guard Self.running[ObjectIdentifier(window)] === self else { return }
        stop()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        watchdog?.invalidate()
        watchdog = nil
        Self.running[ObjectIdentifier(window)] = nil
    }

    /// y of a CSS cubic-bezier timing curve at x, by bisection (a few dozen steps, once a frame).
    static func solve(_ c: (Double, Double, Double, Double), _ x: Double) -> Double {
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bez(mid, c.0, c.2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, c.1, c.3)
    }
}

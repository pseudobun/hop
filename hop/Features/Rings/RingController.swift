import AppKit

/// Opens rings on their triggers, follows the pointer and runs the slice it lets go on.
///
/// Gestures:
/// - hold the trigger, move toward a slice, let go: it runs (`fireOn: "release"`), or click it (`"click"`)
/// - let go inside the dead zone, press Escape or right-click: nothing runs
/// - flick on past a group: its slices fan out further along; come back inside to return
/// - scroll while holding: the next ring on the same trigger
/// - 1 to 8: run that slice straight away
/// - a trackpad tap, a fan (Switch App, Convert…) or a group let go on: stays open until a click
final class RingController {
    private var config = HopConfig.Rings()
    private let tap: RingEventTap
    private var trackpad: TrackpadTaps?
    private var hotkeys: [RingTrigger: GlobalHotkey] = [:]
    private(set) var problems: [String] = []

    private struct Session {
        var trigger: RingTrigger?
        var candidates: [HopConfig.Ring]
        var index: Int
        var levels: [RingLevel]
        var aimed: Int?
        /// Open until a click or Escape (trackpad tap, fan).
        var sticky: Bool
        var context: RingContext
        var openedAt = Date()
        /// The pointer left the dead zone at some point (a held mouse button then is not a click).
        var travelled = false
        var scrollAccumulator = 0.0
    }

    private var session: Session?
    private var panel: RingPanel?
    private var view: RingView?
    private var timer: Timer?
    /// The ring last used on each trigger opens first next time.
    private var lastUsed: [RingTrigger: String] = [:]

    static let cliNotification = Notification.Name(AppPaths.bundleID + ".ring")
    private var cliObserver: NSObjectProtocol?

    init() {
        tap = RingEventTap { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { RingController.current?.handle(event) } }
        }
        cliObserver = DistributedNotificationCenter.default().addObserver(forName: Self.cliNotification, object: nil, queue: .main) { note in
            let open = note.userInfo?["open"] as? String, run = note.userInfo?["run"] as? String
            MainActor.assumeIsolated {
                guard let self = RingController.current else { return }
                if let open, !self.open(named: open) { HUD.shared.fail("No ring \(open)") }
                if let run, let ref = RingActionRef.parse(run) { self.run(ref) }
            }
        }
    }

    /// Runs one action as if its slice fired (`hop ring run`).
    func run(_ ref: RingActionRef) {
        let node = RingRunner.node(ref)
        let front = NSWorkspace.shared.frontmostApplication
        let ctx = RingContext(app: front?.processIdentifier == getpid() ? nil : front, point: NSEvent.mouseLocation)
        switch node.kind {
        case .run(_, let perform): Task { report(await perform(ctx), at: ctx.point) }
        case .broken(let reason): HUD.shared.warn(reason)
        case .group: break
        }
    }

    nonisolated(unsafe) private static weak var current: RingController?

    // MARK: Config

    func apply(_ rings: HopConfig.Rings) {
        Self.current = self
        config = rings
        close()
        hotkeys.values.forEach { $0.unregister() }
        hotkeys = [:]
        trackpad?.stop()
        trackpad = nil
        problems = []
        guard rings.enabled else {
            tap.stop()
            return
        }
        AppHistory.shared.start()
        var triggers = Set<RingTrigger>()
        for (text, owner) in allTriggerTexts() {
            guard !text.isEmpty else { continue }
            guard let t = RingTrigger.parse(text) else {
                problems.append("“\(text)” for \(owner) is not a ring trigger")
                continue
            }
            triggers.insert(t)
        }
        var buttons = Set<Int>(), fn = false, taps = Set<Int>()
        for t in triggers {
            switch t {
            case .hotkey(let spec):
                let hk = GlobalHotkey(onPress: { [weak self] in self?.handle(.triggerDown(t)) },
                                      onRelease: { [weak self] in self?.handle(.triggerUp(t)) })
                if hk.register(keyCode: spec.keyCode, modifiers: spec.modifiers) { hotkeys[t] = hk }
                else { problems.append("\(t.display) for a ring is taken by another app or macOS") }
            case .mouse(let b): buttons.insert(b)
            case .fn: fn = true
            case .tap(let n): taps.insert(n)
            }
        }
        tap.update { $0.mouseButtons = buttons; $0.fn = fn; $0.digits = rings.digits }
        // The tap also serves keys and clicks while a ring is open, so it runs whenever a trigger is set
        // (a ring opened from the launcher or CLI starts it on demand).
        if triggers.isEmpty { tap.stop() }
        else if !tap.start() { problems.append("Rings need Accessibility for clicks, digits and mouse or fn triggers") }
        if !taps.isEmpty {
            let t = TrackpadTaps(fingers: taps) { n in
                DispatchQueue.main.async { MainActor.assumeIsolated { RingController.current?.trackpadTap(n) } }
            }
            if t.start() { trackpad = t } else { problems.append("No trackpad for tap triggers") }
        }
    }

    func stop() {
        close()
        tap.stop()
        trackpad?.stop()
        hotkeys.values.forEach { $0.unregister() }
    }

    private func allTriggerTexts() -> [(String, String)] {
        var out = [(config.appTrigger, "rings.appTrigger"), (config.mediaTrigger, "rings.mediaTrigger")]
        for r in config.rings where r.app.isEmpty { out.append((r.trigger, r.name.isEmpty ? "a ring" : r.name)) }
        return out
    }

    /// Every ring that answers `trigger` right now, the app ring of the app in front first.
    private func candidates(for trigger: RingTrigger, front: NSRunningApplication?) -> [HopConfig.Ring] {
        var out: [HopConfig.Ring] = []
        if RingTrigger.parse(config.appTrigger) == trigger, let id = front?.bundleIdentifier, let ring = appRing(for: id) {
            out.append(ring)
        }
        var rest = config.rings.filter { $0.app.isEmpty && RingTrigger.parse($0.trigger) == trigger }
        if RingTrigger.parse(config.mediaTrigger) == trigger { rest.append(RingPresets.media) }
        if let last = lastUsed[trigger], let i = rest.firstIndex(where: { $0.name == last }) { rest.insert(rest.remove(at: i), at: 0) }
        return out + rest
    }

    func appRing(for bundleID: String) -> HopConfig.Ring? {
        config.rings.first { $0.app.caseInsensitiveCompare(bundleID) == .orderedSame }
            ?? (config.builtInAppRings ? RingPresets.apps.first { $0.app == bundleID } : nil)
    }

    // MARK: Opening

    /// Opens a ring at the pointer, from a trigger or by name (`hop ring <name>`, a launcher command).
    func open(_ rings: [HopConfig.Ring], trigger: RingTrigger?, sticky: Bool) {
        guard !rings.isEmpty else { return }
        let point = NSEvent.mouseLocation
        let front = NSWorkspace.shared.frontmostApplication
        let ctx = RingContext(app: front?.processIdentifier == getpid() ? nil : front, point: point)
        session = Session(trigger: trigger, candidates: rings, index: 0, levels: [], sticky: sticky, context: ctx)
        show(rings[0], at: point)
    }

    func open(named name: String) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let lower = name.lowercased()
        let ring: HopConfig.Ring?
        switch lower {
        case "media": ring = RingPresets.media
        case "app": ring = front?.bundleIdentifier.flatMap(appRing(for:))
        default: ring = config.rings.first { $0.name.lowercased() == lower } ?? RingPresets.apps.first { $0.name.lowercased() == lower }
        }
        guard let ring else { return false }
        open([ring], trigger: nil, sticky: true)
        return true
    }

    private func show(_ ring: HopConfig.Ring, at point: CGPoint) {
        let nodes = ring.slices.prefix(8).map(RingRunner.node)
        let layout = RingLayout(center: point, count: nodes.count, scale: config.scale, deadZone: config.deadZone.radius)
        session?.levels = [RingLevel(title: ring.name.isEmpty ? "hop" : ring.name, nodes: Array(nodes), layout: layout,
                                     states: Array(repeating: nil, count: nodes.count))]
        session?.aimed = nil
        readStates(level: 0)
        present(at: point)
    }

    private func present(at point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!
        if panel == nil || panel?.frame != screen.frame {
            panel?.orderOut(nil)
            let p = RingPanel(screen: screen)
            let v = RingView(frame: CGRect(origin: .zero, size: screen.frame.size))
            p.contentView = v
            panel = p
            view = v
        }
        guard let view, let panel else { return }
        view.origin = screen.frame.origin
        view.scale = config.scale
        view.digits = config.digits
        view.appear = 0
        sync()
        panel.orderFrontRegardless()
        if !tap.isRunning { _ = tap.start() }
        tap.update { $0.open = true }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func readStates(level: Int) {
        guard let s = session, level < s.levels.count else { return }
        let opened = s.openedAt
        for (i, node) in s.levels[level].nodes.enumerated() {
            guard let read = node.readState else { continue }
            Task {
                let value = await read()
                guard let cur = session, cur.openedAt == opened, level < cur.levels.count, i < cur.levels[level].states.count else { return }
                session?.levels[level].states[i] = value
                sync()
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        session = nil
        panel?.orderOut(nil)
        tap.update { $0.open = false }
    }

    var isOpen: Bool { session != nil }

    // MARK: Following the pointer

    private func tick() {
        guard var s = session, let view else { return }
        if view.appear < 1 { view.appear = min(1, view.appear + 0.14) }
        let p = NSEvent.mouseLocation
        var top = s.levels.count - 1
        // Back inside a parent ring: leave the group.
        while top > 0, s.levels[top - 1].layout.distance(p) < s.levels[top - 1].layout.radius - s.levels[top - 1].layout.bubble,
              s.levels[top].layout.facing != nil {
            s.levels.removeLast()
            top -= 1
        }
        let layout = s.levels[top].layout
        if layout.distance(p) > layout.deadZone { s.travelled = true }
        var aimed = layout.aimed(at: p)
        // Past a group: its children fan out from there.
        if let a = aimed, case .group(let children) = s.levels[top].nodes[a].kind, layout.isBeyond(p) {
            let origin = layout.position(a)
            let facing = atan2(origin.y - layout.center.y, origin.x - layout.center.x)
            let child = RingLayout(center: origin, count: children.count, scale: config.scale, deadZone: config.deadZone.radius, facing: facing)
            s.levels.append(RingLevel(title: s.levels[top].nodes[a].title, nodes: children, layout: child,
                                      states: Array(repeating: nil, count: children.count)))
            aimed = child.aimed(at: p)
            session = s
            readStates(level: s.levels.count - 1)
            s = session!
        }
        if aimed != s.aimed {
            s.aimed = aimed
            if aimed != nil { feedback() }
        }
        session = s
        view.pointer = p
        sync()
    }

    private func sync() {
        guard let view, let s = session else { return }
        view.levels = s.levels
        view.aimed = s.aimed
        view.needsDisplay = true
    }

    private func feedback() {
        if config.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        if config.sounds { Self.tick?.stop(); Self.tick?.play() }
    }

    private static let tick: NSSound? = {
        let s = NSSound(named: "Tink")
        s?.volume = 0.25
        return s
    }()

    private static let fired: NSSound? = {
        let s = NSSound(named: "Pop")
        s?.volume = 0.3
        return s
    }()

    // MARK: Input

    private func handle(_ event: RingInputEvent) {
        switch event {
        case .triggerDown(let t):
            if session != nil {
                // A tap ring open and the same tap again, or a second press: close.
                if session?.trigger == t { close() }
                return
            }
            let front = NSWorkspace.shared.frontmostApplication
            let rings = candidates(for: t, front: front)
            guard !rings.isEmpty else {
                if RingTrigger.parse(config.appTrigger) == t {
                    HUD.shared.warn("No ring for \(front?.localizedName ?? "this app")")
                }
                if case .mouse(let b) = t { RingEventTap.postClick(button: b, at: Self.cgPoint(NSEvent.mouseLocation)) }
                return
            }
            open(rings, trigger: t, sticky: !t.isHeld)
        case .triggerUp(let t):
            guard let s = session, s.trigger == t, !s.sticky else { return }
            // A short press of a mouse trigger that never left the dead zone is a plain click.
            if case .mouse(let b) = t, !s.travelled, Date().timeIntervalSince(s.openedAt) < 0.25 {
                close()
                RingEventTap.postClick(button: b, at: Self.cgPoint(NSEvent.mouseLocation))
                return
            }
            if config.fireOn == .release, let a = s.aimed { fire(a, how: .release) } else { close() }
        case .click:
            guard let s = session else { return }
            if let a = s.aimed { fire(a, how: .click) } else { close() }
        case .digit(let i):
            guard let s = session, let level = s.levels.last, i < level.nodes.count else { return }
            fire(i, how: .digit)
        case .escape:
            close()
        case .otherKey:
            if session?.trigger == .fn, session?.aimed == nil { close() }
        case .scroll(let dy):
            guard var s = session, s.levels.count == 1, s.candidates.count > 1 else { return }
            s.scrollAccumulator += dy
            guard abs(s.scrollAccumulator) > 6 else { session = s; return }
            s.index = (s.index + (s.scrollAccumulator > 0 ? -1 : 1) + s.candidates.count) % s.candidates.count
            s.scrollAccumulator = 0
            session = s
            let ring = s.candidates[s.index]
            if let t = s.trigger { lastUsed[t] = ring.name }
            show(ring, at: s.levels[0].layout.center)
            feedback()
        }
    }

    private func trackpadTap(_ fingers: Int) {
        handle(.triggerDown(.tap(fingers)))
    }

    private enum How { case release, click, digit }

    private func fire(_ index: Int, how: How) {
        guard let s = session, let level = s.levels.last, index < level.nodes.count else { return }
        let node = level.nodes[index]
        let ringName = s.levels.first?.title ?? ""
        let keepOpen = how != .release && (s.candidates[safeIndex: s.index]?.keepOpen ?? false) && s.levels.count == 1
        switch node.kind {
        case .broken(let reason):
            HUD.shared.warn(reason)
            if !keepOpen { close() }
        case .group(let children):
            // Let go on a group: its slices stay up as a ring of their own.
            let center = s.levels[0].layout.center
            session?.sticky = true
            session?.levels = [RingLevel(title: node.title, nodes: children,
                                         layout: RingLayout(center: center, count: children.count, scale: config.scale,
                                                            deadZone: config.deadZone.radius),
                                         states: Array(repeating: nil, count: children.count))]
            session?.aimed = nil
            readStates(level: 0)
            sync()
        case .run(let key, let perform):
            if config.statistics { RingStats.shared.record(key, ring: ringName) }
            if config.sounds { Self.fired?.play() }
            let ctx = s.context
            if keepOpen {
                Task {
                    report(await perform(ctx), at: ctx.point)
                    try? await Task.sleep(for: .milliseconds(250))
                    if session != nil { readStates(level: 0) }
                }
            } else {
                close()
                Task { report(await perform(ctx), at: ctx.point) }
            }
        }
    }

    private func report(_ outcome: RingOutcome, at point: CGPoint) {
        switch outcome {
        case .done: break
        case .hud(let text): HUD.shared.show(text)
        case .warn(let text): HUD.shared.warn(text)
        case .fail(let text): HUD.shared.fail(text)
        case .fan(let title, let nodes):
            guard !nodes.isEmpty else { return }
            let front = NSWorkspace.shared.frontmostApplication
            session = Session(trigger: nil, candidates: [], index: 0, levels: [], sticky: true,
                              context: RingContext(app: front?.processIdentifier == getpid() ? nil : front, point: point))
            let layout = RingLayout(center: point, count: nodes.count, scale: config.scale, deadZone: config.deadZone.radius)
            session?.levels = [RingLevel(title: title, nodes: nodes, layout: layout, states: Array(repeating: nil, count: nodes.count))]
            present(at: point)
        }
    }

    static func cgPoint(_ p: NSPoint) -> CGPoint {
        // AppKit's origin is the bottom left of the main screen; CG's the top left.
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    // MARK: Debug

    /// Renders a ring to a PNG without a trigger (DebugRing).
    func debugRender(_ ring: HopConfig.Ring, aimed: Int?, group: Bool, to path: String) {
        let size = CGSize(width: 680, height: 680)
        let center = CGPoint(x: 340, y: 340)
        let nodes = ring.slices.prefix(8).map(RingRunner.node)
        let layout = RingLayout(center: center, count: nodes.count, scale: config.scale, deadZone: config.deadZone.radius)
        var levels = [RingLevel(title: ring.name, nodes: Array(nodes), layout: layout, states: nodes.map { $0.readState == nil ? nil : false })]
        if group, let a = aimed, case .group(let children) = nodes[a].kind {
            let origin = layout.position(a)
            let child = RingLayout(center: origin, count: children.count, scale: config.scale, deadZone: config.deadZone.radius,
                                   facing: atan2(origin.y - center.y, origin.x - center.x))
            levels.append(RingLevel(title: nodes[a].title, nodes: children, layout: child, states: Array(repeating: nil, count: children.count)))
        }
        let v = RingView(frame: CGRect(origin: .zero, size: size))
        v.appearance = Theme.appearance
        v.levels = levels
        v.aimed = group ? 0 : aimed
        v.scale = config.scale
        let target = group ? levels.last!.layout.position(0) : (aimed.map { layout.position($0) } ?? center)
        v.pointer = target
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.appearance?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            Theme.wash(0.06).setFill()
            Theme.background.withAlphaComponent(0.6).setFill()
            NSBezierPath(rect: v.bounds).fill()
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private extension Array {
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

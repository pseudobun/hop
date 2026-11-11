import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// What the ring hears from the outside world.
enum RingInputEvent {
    case triggerDown(RingTrigger)
    case triggerUp(RingTrigger)
    /// A held trigger that was let go before the ring did anything (a plain middle click).
    case click
    case digit(Int)
    case escape
    case scroll(Double)
    /// Any other key went down while a held trigger was open (fn used as a modifier).
    case otherKey
}

/// One event tap for mouse-button and fn triggers and for keys, clicks and scrolls while a
/// ring is open. Runs on its own thread like the Hyper tap; the decision to swallow an event
/// is made there, from a snapshot the main thread keeps current.
nonisolated final class RingEventTap: @unchecked Sendable {
    struct Snapshot {
        var mouseButtons: Set<Int> = []
        var fn = false
        /// A ring is on screen: clicks, digits, Escape and scrolls are the ring's.
        var open = false
        var digits = true
    }

    /// Marks events hop posts itself (a passed-through middle click), so the tap lets them go.
    static let syntheticMarker: Int64 = 0x686F_7052 // 'hopR'

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let send: @Sendable (RingInputEvent) -> Void
    // Tap thread only.
    private var fnDown = false
    private var swallowLeftUp = false

    init(send: @escaping @Sendable (RingInputEvent) -> Void) { self.send = send }

    func update(_ change: (inout Snapshot) -> Void) { lock.withLock { change(&snapshot) } }
    private var current: Snapshot { lock.withLock { snapshot } }

    var isRunning: Bool { tap != nil }

    /// Needs Accessibility; false when the tap could not be created.
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .otherMouseDown, .otherMouseUp, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<RingEventTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = port
        let t = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "hop.ring-tap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }
        let s = current
        switch type {
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard s.mouseButtons.contains(button) else { return s.open ? nil : pass }
            send(type == .otherMouseDown ? .triggerDown(.mouse(button)) : .triggerUp(.mouse(button)))
            return nil
        case .flagsChanged:
            guard s.fn else { return pass }
            let down = event.flags.contains(.maskSecondaryFn)
            // Only fn on its own: with other modifiers it is part of a shortcut.
            let others = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if down && !fnDown && others.isEmpty {
                fnDown = true
                send(.triggerDown(.fn))
            } else if !down && fnDown {
                fnDown = false
                send(.triggerUp(.fn))
            }
            return pass
        case .keyDown:
            guard s.open else { return pass }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if code == kVK_Escape { send(.escape); return nil }
            let digitCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]
            if s.digits, let i = digitCodes.firstIndex(of: code) { send(.digit(i)); return nil }
            if fnDown { send(.otherKey) }
            return pass
        case .leftMouseDown:
            guard s.open else { return pass }
            swallowLeftUp = true
            send(.click)
            return nil
        case .leftMouseUp:
            guard swallowLeftUp else { return pass }
            swallowLeftUp = false
            return nil
        case .rightMouseDown:
            guard s.open else { return pass }
            send(.escape)
            return nil
        case .scrollWheel:
            guard s.open else { return pass }
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            if dy != 0 { send(.scroll(dy)) }
            return nil
        default:
            return pass
        }
    }

    /// Posts a click of `button` that the tap lets through (a short press of a trigger button).
    static func postClick(button: Int, at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for (type, down) in [(CGEventType.otherMouseDown, true), (.otherMouseUp, false)] {
            _ = down
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
}

/// Three- and four-finger trackpad taps, read from the private MultitouchSupport framework
/// (as MiddleClick and Jitouch do). Loaded only when a ring uses a tap trigger.
nonisolated final class TrackpadTaps: @unchecked Sendable {
    private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void

    nonisolated(unsafe) static var shared: TrackpadTaps?

    private let fingers: Set<Int>
    private let onTap: @Sendable (Int) -> Void
    private var devices: [UnsafeMutableRawPointer] = []
    private let lock = NSLock()
    // Gesture state (callback thread).
    private var maxFingers = 0
    private var startedAt = 0.0
    private var startPositions: [Int32: (Float, Float)] = [:]
    private var moved = false

    init(fingers: Set<Int>, onTap: @escaping @Sendable (Int) -> Void) {
        self.fingers = fingers
        self.onTap = onTap
    }

    private nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    func start() -> Bool {
        guard let list = Self.fn("MTDeviceCreateList", DeviceList.self), let register = Self.fn("MTRegisterContactFrameCallback", Register.self),
              let start = Self.fn("MTDeviceStart", Start.self), let array = list()?.takeRetainedValue() else { return false }
        let callback: Callback = { _, touches, count, timestamp, _ in
            TrackpadTaps.shared?.frame(touches, Int(count), timestamp)
            return 0
        }
        TrackpadTaps.shared = self
        for i in 0..<CFArrayGetCount(array) {
            guard let device = CFArrayGetValueAtIndex(array, i) else { continue }
            let d = UnsafeMutableRawPointer(mutating: device)
            register(d, callback)
            start(d, 0)
            devices.append(d)
        }
        return !devices.isEmpty
    }

    func stop() {
        if let stop = Self.fn("MTDeviceStop", Stop.self) { devices.forEach { stop($0) } }
        devices = []
        if TrackpadTaps.shared === self { TrackpadTaps.shared = nil }
    }

    /// One frame of touches. MTTouch is 96 bytes; the identifier sits at 16, the normalised position at 32.
    private func frame(_ touches: UnsafeMutableRawPointer?, _ count: Int, _ time: Double) {
        lock.lock()
        defer { lock.unlock() }
        if count == 0 {
            if maxFingers > 0, fingers.contains(maxFingers), !moved, time - startedAt < 0.3 {
                let n = maxFingers
                onTap(n)
            }
            maxFingers = 0
            startPositions = [:]
            moved = false
            return
        }
        if maxFingers == 0 { startedAt = time }
        maxFingers = max(maxFingers, count)
        guard let touches else { return }
        for i in 0..<count {
            let base = touches + i * 96
            let id = base.load(fromByteOffset: 16, as: Int32.self)
            let x = base.load(fromByteOffset: 32, as: Float.self), y = base.load(fromByteOffset: 36, as: Float.self)
            if let start = startPositions[id] {
                if abs(start.0 - x) > 0.04 || abs(start.1 - y) > 0.04 { moved = true }
            } else {
                startPositions[id] = (x, y)
            }
        }
    }
}

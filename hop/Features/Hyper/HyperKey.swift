import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit
import IOKit.hidsystem
import os

/// Caps Lock → F20 via the system HID key mapping (what `hidutil` sets).
nonisolated enum HyperKeyMapping {
    static let capsLock: UInt64 = 0x7_0000_0039
    static let f20: UInt64 = 0x7_0000_006F

    /// Current `UserKeyMapping` entries.
    static func current() async -> [[String: UInt64]] {
        guard let r = try? await ProcessRunner.run("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"]), r.ok
        else { return [] }
        return parse(r.out)
    }

    /// Parses hidutil's plist-ish dump: `( { HIDKeyboardModifierMappingDst = 30064771183; HIDKeyboardModifierMappingSrc = 30064771129; } )`.
    static func parse(_ text: String) -> [[String: UInt64]] {
        var out: [[String: UInt64]] = []
        for block in text.components(separatedBy: "}") {
            var entry: [String: UInt64] = [:]
            for key in ["HIDKeyboardModifierMappingSrc", "HIDKeyboardModifierMappingDst"] {
                guard let r = block.range(of: key) else { continue }
                let rest = block[r.upperBound...].drop { $0 == " " || $0 == "=" }
                let digits = rest.prefix { $0.isNumber || $0 == "x" || $0.isHexDigit }
                let s = String(digits)
                entry[key] = s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : UInt64(s)
            }
            if entry.count == 2 { out.append(entry) }
        }
        return out
    }

    static func json(_ entries: [[String: UInt64]]) -> String {
        let items = entries.map { "{\"HIDKeyboardModifierMappingSrc\":\($0["HIDKeyboardModifierMappingSrc"]!),\"HIDKeyboardModifierMappingDst\":\($0["HIDKeyboardModifierMappingDst"]!)}" }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }

    /// Adds Caps → F20, keeping unrelated mappings; returns false on failure.
    @discardableResult
    static func apply() async -> Bool {
        var entries = await current().filter { $0["HIDKeyboardModifierMappingSrc"] != capsLock }
        entries.append(["HIDKeyboardModifierMappingSrc": capsLock, "HIDKeyboardModifierMappingDst": f20])
        let r = try? await ProcessRunner.run("/usr/bin/hidutil", ["property", "--set", json(entries)])
        guard r?.ok == true else { return false }
        clearCapsLock()
        return true
    }

    /// Turns Caps Lock off. Once Caps sends F20 nothing else could, e.g. after it was
    /// pressed while hop was restarting.
    static func clearCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
    }

    /// Removes our Caps → F20 entry only.
    @discardableResult
    static func restore() async -> Bool {
        let entries = await current().filter {
            !($0["HIDKeyboardModifierMappingSrc"] == capsLock && $0["HIDKeyboardModifierMappingDst"] == f20)
        }
        let r = try? await ProcessRunner.run("/usr/bin/hidutil", ["property", "--set", json(entries)])
        return r?.ok == true
    }

    /// Synchronous restore for termination paths.
    static func restoreBlocking() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await restore(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }
}

/// Event tap on its own thread: while F20 (Caps) is held, other keys get ⌃⌥⌘⇧.
nonisolated final class HyperEventTap: @unchecked Sendable {
    static let f20KeyCode: Int64 = 90
    static let escapeKeyCode: CGKeyCode = 53
    static let hyperFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    private let quickPressEscape: Bool
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    // Touched only on the tap thread.
    private var active = false
    private var usedWithOtherKey = false
    private var pressedAt = Date.distantPast

    init(quickPressEscape: Bool) { self.quickPressEscape = quickPressEscape }

    /// Needs Accessibility; returns false if the tap could not be created.
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HyperEventTap>.fromOpaque(info).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: callback,
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
        t.name = "hop.hyper-tap"
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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.f20KeyCode {
                if type == .keyDown {
                    if !active {
                        active = true
                        usedWithOtherKey = false
                        pressedAt = Date()
                    }
                } else {
                    active = false
                    if quickPressEscape && !usedWithOtherKey && Date().timeIntervalSince(pressedAt) < 0.35 {
                        postEscape()
                    }
                }
                return nil // swallow F20
            }
            if active {
                usedWithOtherKey = true
                event.flags = event.flags.union(Self.hyperFlags)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func postEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: Self.escapeKeyCode, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: Self.escapeKeyCode, keyDown: false)?.post(tap: .cgSessionEventTap)
    }
}

/// Turns Hyper on and off with the config, re-applies the mapping when a keyboard
/// is connected and restores it on quit.
final class HyperKeyController {
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var tap: HyperEventTap?
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var signalSources: [DispatchSourceSignal] = []

    var statusText: String {
        if let lastError { return lastError }
        if !isRunning { return "off" }
        return IsSecureEventInputEnabled() ? "on (paused: Secure Input is active)" : "on"
    }

    func update(enabled: Bool, quickPressEscape: Bool) {
        stop()
        guard enabled else { return }
        guard AXIsProcessTrusted() else {
            lastError = "needs Accessibility permission"
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        let t = HyperEventTap(quickPressEscape: quickPressEscape)
        guard t.start() else {
            lastError = "could not create the event tap"
            return
        }
        tap = t
        isRunning = true
        lastError = nil
        Task { await HyperKeyMapping.apply() }
        watchKeyboards()
        installSignalHandlers()
    }

    func stop() {
        guard isRunning else { return }
        tap?.stop()
        tap = nil
        isRunning = false
        if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        HyperKeyMapping.restoreBlocking()
    }

    /// New keyboards start without the user mapping; re-apply after they attach.
    private func watchKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        notifyPort = port
        let matching = IOServiceMatching("IOHIDKeyboard")
        let callback: IOServiceMatchingCallback = { _, iterator in
            while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await HyperKeyMapping.apply()
            }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, callback, nil, &iterator)
        while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) } // arm the notification
    }

    private func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler {
                HyperKeyMapping.restoreBlocking()
                exit(0)
            }
            s.resume()
            signalSources.append(s)
        }
    }
}

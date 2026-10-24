import AppKit
import Carbon.HIToolbox

/// Text expansion: watches typing through an event tap (its own thread, Accessibility)
/// and replaces a snippet keyword with the snippet as soon as it is typed.
final class SnippetExpander {
    /// Marks the events hop posts itself, so the tap ignores them.
    nonisolated static let marker: Int64 = 0x686F_7073 // 'hops'

    var keywords: [(keyword: String, index: Int)] = [] {
        didSet { state.setKeywords(keywords.map(\.keyword)) }
    }
    var withinWords = false
    var disabledApps: Set<String> = []
    /// Called on the main thread with the index of the snippet to expand and its keyword.
    var onMatch: ((Int, String) -> Void)?

    private let state = TapState()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { tap != nil }

    /// Needs Accessibility; false when the tap could not be created.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let state = Unmanaged<TapState>.fromOpaque(info).takeUnretainedValue()
            state.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: callback,
                                           userInfo: Unmanaged.passUnretained(state).toOpaque())
        else { return false }
        tap = port
        state.tap = port
        state.onMatch = { [weak self] keyword in
            DispatchQueue.main.async { self?.matched(keyword) }
        }
        let t = Thread { [weak self] in
            guard let tap = self?.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "hop.snippet-tap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        // Typing in another app starts a new word.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.reset() }
        })
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        tap = nil
        runLoop = nil
        thread = nil
        state.tap = nil
    }

    private func matched(_ typed: String) {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, disabledApps.contains(id) { return }
        guard let m = SnippetMatcher.match(typed, keywords: keywords, withinWords: withinWords) else { return }
        state.reset()
        onMatch?(m.index, m.keyword)
    }

    // MARK: Typing into the front app

    /// Deletes the keyword, pastes `text` and moves the caret back to `{cursor}`.
    static func replace(keyword: String, with text: String, caretBack: Int?) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<keyword.count { tap(UInt16(kVK_Delete), source: source) }
        try? await Task.sleep(for: .milliseconds(30))
        await insert(text, caretBack: caretBack)
    }

    /// Pastes through the clipboard (marked transient, then restored) so any text works.
    static func insert(_ text: String, caretBack: Int?) async {
        _ = await Pasteboard.paste(text, concealed: false)
        if let back = caretBack, back > 0 {
            try? await Task.sleep(for: .milliseconds(120))
            let source = CGEventSource(stateID: .combinedSessionState)
            for _ in 0..<back { tap(UInt16(kVK_LeftArrow), source: source) }
        }
    }

    private static func tap(_ key: UInt16, source: CGEventSource?) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.setIntegerValueField(.eventSourceUserData, value: marker)
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// What the tap thread sees: the last characters typed, reset by anything that moves
/// the caret elsewhere.
private final class TapState: @unchecked Sendable {
    var tap: CFMachPort?
    var onMatch: ((String) -> Void)?
    private let lock = NSLock()
    private var buffer = ""
    private var lastCharacters: Set<Character> = []
    private var maxLength = 1

    func setKeywords(_ keywords: [String]) {
        lock.lock()
        lastCharacters = Set(keywords.compactMap(\.last))
        maxLength = max(1, (keywords.map(\.count).max() ?? 1) + 1)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        buffer = ""
        lock.unlock()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown:
            reset()
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == SnippetExpander.marker { return }
            let flags = event.flags
            if flags.contains(.maskCommand) || flags.contains(.maskControl) { reset(); return }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            switch code {
            case kVK_Delete:
                lock.lock()
                if !buffer.isEmpty { buffer.removeLast() }
                lock.unlock()
                return
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                 kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
                reset()
                return
            default:
                break
            }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
            guard length > 0 else { return }
            let typed = String(utf16CodeUnits: chars, count: length)
            lock.lock()
            buffer += typed
            if buffer.count > maxLength { buffer = String(buffer.suffix(maxLength)) }
            let snapshot = buffer
            let candidate = typed.last.map { lastCharacters.contains($0) } ?? false
            lock.unlock()
            if candidate { onMatch?(snapshot) }
        default:
            break
        }
    }
}

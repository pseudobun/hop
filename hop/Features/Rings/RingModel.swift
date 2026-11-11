import AppKit
import Carbon.HIToolbox

/// What opens a ring.
nonisolated enum RingTrigger: Hashable, Sendable {
    /// A hotkey held down ("hyper+space"); letting go of its key fires.
    case hotkey(HotkeySpec)
    /// The fn (Globe) key held alone.
    case fn
    /// A mouse button held: 2 is the middle button (written "mouse3"), 3 and 4 the side buttons.
    case mouse(Int)
    /// A tap with 3 or 4 fingers on the trackpad; the ring stays open until a click.
    case tap(Int)

    static func parse(_ text: String) -> RingTrigger? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t == "fn" || t == "globe" { return .fn }
        if t == "middle" || t == "middlemouse" { return .mouse(2) }
        if t.hasPrefix("mouse"), let n = Int(t.dropFirst(5)), (3...8).contains(n) { return .mouse(n - 1) }
        if t.hasPrefix("tap"), let n = Int(t.dropFirst(3)), n == 3 || n == 4 { return .tap(n) }
        return HotkeySpec.parse(t).map(RingTrigger.hotkey)
    }

    /// Held triggers fire on release; a tap leaves the ring open.
    var isHeld: Bool { if case .tap = self { false } else { true } }

    @MainActor var display: String {
        switch self {
        case .hotkey(let spec): spec.display
        case .fn: "fn"
        case .mouse(let b): b == 2 ? "Middle Button" : "Mouse \(b + 1)"
        case .tap(let n): "\(n)-Finger Tap"
        }
    }
}

/// A key combination sent to the app in front: "cmd+shift+t", "ctrl+left", "f11".
nonisolated struct KeyStroke: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static func parse(_ text: String) -> KeyStroke? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let code = HotkeySpec.keyCodes[keyName] ?? extraKeys[keyName] else { return nil }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "alt", "opt", "option", "⌥": flags.insert(.maskAlternate)
            case "shift", "⇧": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            case "hyper": flags.formUnion([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            default: return nil
            }
        }
        return KeyStroke(keyCode: CGKeyCode(code), flags: flags)
    }

    static let extraKeys: [String: Int] = [
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "esc": kVK_Escape,
    ]

    /// Posts the key down and up; modifiers ride on the events, nothing stays held.
    func post() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
}

/// What a slice runs. Written as one string in the config:
///
/// | Form | Runs |
/// |---|---|
/// | `dark-mode` | a built-in action (see `RingCatalog`) |
/// | `clipboard.history`, `system.emptyTrash` | any hop command, by id or title |
/// | `app:Safari`, `app:com.apple.Safari` | opens the app, or brings it forward |
/// | `key:cmd+shift+t` | sends the keystroke to the app in front |
/// | `type:/model opus` | types the text (`\n` presses Return) |
/// | `menu:File > New Tab` | clicks that menu item of the app in front |
/// | `shortcut:Name` | runs an Apple Shortcut |
/// | `url:https://…`, or any `scheme://…` | opens the link |
/// | `folder:~/Downloads` | opens the folder in Finder |
/// | `shell:say hi` | runs the command with `/bin/zsh -lc` |
/// | `applescript:…` | runs the AppleScript |
nonisolated enum RingActionRef: Equatable, Sendable {
    case builtin(String)
    case command(String)
    case app(String)
    case key(KeyStroke)
    case type(String)
    case menu([String])
    case shortcut(String)
    case url(String)
    case folder(String)
    case shell(String)
    case appleScript(String)

    static func parse(_ text: String) -> RingActionRef? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let colon = t.firstIndex(of: ":") {
            let scheme = t[..<colon].lowercased()
            let rest = String(t[t.index(after: colon)...])
            let value = rest.trimmingCharacters(in: .whitespaces)
            switch scheme {
            case "app": return value.isEmpty ? nil : .app(value)
            case "key", "keys", "keystroke": return KeyStroke.parse(value).map(RingActionRef.key)
            case "type", "text": return rest.isEmpty ? nil : .type(rest.replacingOccurrences(of: "\\n", with: "\n"))
            case "menu":
                let path = value.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return path.count >= 2 ? .menu(path) : nil
            case "shortcut": return value.isEmpty ? nil : .shortcut(value)
            case "url", "link": return value.isEmpty ? nil : .url(value)
            case "folder": return value.isEmpty ? nil : .folder(value)
            case "shell", "sh": return value.isEmpty ? nil : .shell(value)
            case "applescript", "osascript": return value.isEmpty ? nil : .appleScript(value)
            case "hop", "command": return value.isEmpty ? nil : .command(value)
            default:
                if rest.hasPrefix("//") { return .url(t) }
            }
        }
        if RingCatalog.entry(t) != nil { return .builtin(t) }
        return .command(t)
    }
}

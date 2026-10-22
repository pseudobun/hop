import Carbon.HIToolbox

/// Parses hotkeys like "cmd+space", "alt+space", "hyper+k", "ctrl+shift+f5".
nonisolated struct HotkeySpec: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static func parse(_ text: String) -> HotkeySpec? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            case "hyper": mods |= UInt32(cmdKey | controlKey | optionKey | shiftKey)
            default: return nil
            }
        }
        guard mods != 0 || keyName.hasPrefix("f") && keyName.count > 1 else { return nil }
        return HotkeySpec(keyCode: UInt32(code), modifiers: mods)
    }

    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "`": kVK_ANSI_Grave,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in f.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()
}

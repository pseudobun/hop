import AppKit

enum ItemIcon {
    case file(String)
    case symbol(String, tint: NSColor? = nil)
    case image(NSImage)
    case emoji(String)
}

/// A keyboard shortcut bound to an action: `↵` or a character, plus modifiers.
struct KeyCombo: Equatable {
    enum Key: Equatable { case returnKey, character(String) }

    let key: Key
    let modifiers: NSEvent.ModifierFlags

    static func ret(_ modifiers: NSEvent.ModifierFlags = []) -> KeyCombo { KeyCombo(key: .returnKey, modifiers: modifiers) }
    static func cmd(_ c: String, _ extra: NSEvent.ModifierFlags = []) -> KeyCombo {
        KeyCombo(key: .character(c), modifiers: extra.union(.command))
    }

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func matches(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(Self.relevant)
        guard mods == modifiers else { return false }
        switch key {
        case .returnKey:
            return event.keyCode == 36 || event.keyCode == 76
        case .character(let c):
            return event.charactersIgnoringModifiers?.lowercased() == c.lowercased()
        }
    }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .returnKey: s += "↵"
        case .character(let c): s += c.uppercased()
        }
        return s
    }
}

enum ActionResult {
    /// Hide the launcher.
    case dismiss
    /// Hide the launcher and flash a HUD.
    case dismissWithHUD(String)
    /// Keep the launcher as is.
    case stay
    /// Keep the launcher open and flash a HUD.
    case stayWithHUD(String)
    /// Enter a sub-mode.
    case push(Mode)
    /// Leave the current sub-mode.
    case pop
    /// Re-run the current query.
    case reload
}

struct Action {
    enum Style { case normal, destructive }

    let title: String
    var symbol: String?
    var shortcut: KeyCombo?
    var style: Style = .normal
    let perform: () async -> ActionResult
}

struct Item {
    let id: String
    var title: String
    var subtitle: String?
    var icon: ItemIcon?
    /// Short right-aligned text, e.g. "Application".
    var accessory: String?
    /// `actions[0]` runs on ↵.
    var actions: [Action]
    /// Root items opened from search get a frecency visit.
    var tracksFrecency = true
    /// Tab also runs the primary action (it enters a sub-mode).
    var pushesMode = false
}

struct ResultSection {
    var title: String?
    var items: [Item]
}

import AppKit

enum ItemIcon {
    /// The Finder icon of a file or app.
    case file(String)
    /// An image file's own contents (svg, png, …).
    case imageFile(String)
    case symbol(String, tint: NSColor? = nil)
    case image(NSImage)
    case emoji(String)
    /// White SF Symbol on a coloured rounded tile, like System Settings icons.
    case tile(String, NSColor)
}

/// Feature colours, all design-system tokens (see Theme).
enum Palette {
    static var wireguard: NSColor { Theme.chart4 }
    static var keepass: NSColor { Theme.good }
    static var notes: NSColor { Theme.chart2 }
    static var clipboard: NSColor { Theme.chart3 }
    static var snippets: NSColor { Theme.chart5 }
    static var files: NSColor { Theme.chart1 }
    static var shelf: NSColor { Theme.info }
    static var messages: NSColor { Theme.good }
    static var calendar: NSColor { Theme.chart4 }
    static var translate: NSColor { Theme.chart1 }
    static var ocr: NSColor { Theme.chart5 }
    static var emoji: NSColor { Theme.chart2 }
    static var neutral: NSColor { Theme.mutedForeground }
}

/// A keyboard shortcut bound to an action: `↵` or a character, plus modifiers.
struct KeyCombo: Equatable {
    enum Key: Equatable { case returnKey, delete, character(String) }

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
        case .delete:
            return event.keyCode == 51
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
        case .delete: s += "⌫"
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
    /// Keep the launcher open and flash a red HUD: the action failed.
    case failWithHUD(String)
    /// Keep the launcher open and flash an amber HUD: nothing to do, e.g. no URL set.
    case warnWithHUD(String)
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

    /// Explicit symbol, or one picked from the title.
    var resolvedSymbol: String {
        if let symbol { return symbol }
        let t = title.lowercased()
        let rules: [(String, String)] = [
            ("show in finder", "folder"), ("bundle identifier", "number"), ("copy path", "link"), ("pid", "number"),
            ("password", "key"), ("username", "person"), ("totp", "clock"), ("open url", "safari"), ("url", "link"),
            ("uninstall", "trash"), ("trash", "trash"), ("force kill", "bolt.fill"), ("kill", "xmark.octagon"),
            ("unpin", "star.slash"), ("pin", "star"), ("unlock", "lock.open"), ("lock", "lock"),
            ("disconnect", "bolt.horizontal.circle"), ("connect", "bolt.horizontal.circle.fill"),
            ("restart", "arrow.clockwise"), ("quit", "power"), ("config", "gearshape"), ("settings", "gearshape"), ("database", "cylinder.split.1x2"),
            ("paste", "doc.on.clipboard"), ("copy", "doc.on.doc"), ("open", "arrow.up.forward.app"),
            ("search", "magnifyingglass"), ("downloads", "arrow.down"), ("cancel", "xmark"),
        ]
        return rules.first { t.contains($0.0) }?.1 ?? "circle.dotted"
    }
}

struct Item {
    let id: String
    var title: String
    var subtitle: String?
    /// Other names root search matches like the title, e.g. "hass".
    var aliases: [String] = []
    var icon: ItemIcon?
    /// Short right-aligned text, e.g. "Application".
    var accessory: String?
    /// `actions[0]` runs on ↵.
    var actions: [Action]
    /// Root items opened from search get a frecency visit.
    var tracksFrecency = true
    /// Tab also runs the primary action (it enters a sub-mode).
    var pushesMode = false
    /// One tinted status chip, e.g. "Connected"; facts go in `accessory`.
    var chip: Chip?
    /// App is open: a Dock-style dot under the icon.
    var isRunning = false
    /// Title is a value (a number), set in mono.
    var monoTitle = false
    /// Large two-sided calculator card instead of a normal row.
    var calculation: (expression: String, result: String, left: String, right: String)?
    /// A colour swatch on the calculation card.
    var swatch: NSColor?
}

struct ResultSection {
    var title: String?
    var items: [Item]
}

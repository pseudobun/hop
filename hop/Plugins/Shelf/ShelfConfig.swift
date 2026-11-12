import Foundation

nonisolated extension HopConfig {
    nonisolated struct Shelf: PluginConfig {
        static let key = "shelf"
        var enabled = true
        /// Shake the pointer while dragging to open a shelf under it.
        var shake = true
        var shakeSensitivity: ShakeDetector.Sensitivity = .medium
        /// Hold exactly these modifiers while dragging to open a shelf; "" turns it off.
        var modifier = "shift"
        /// New empty shelf, new shelf from the clipboard, reopen the last closed shelf.
        var hotkey = ""
        var clipboardHotkey = ""
        var reopenHotkey = ""
        /// Dragged-out items stay on the shelf.
        var keepAfterDragOut = false
        /// Drags that start in these apps never open a shelf (bundle identifiers).
        var ignoreApps: [String] = []
    }

    var shelf: Shelf {
        get { sections[Shelf.self] }
        set { sections[Shelf.self] = newValue }
    }
}

nonisolated extension HopConfig.Shelf {
    private enum Keys: String, CodingKey { case enabled, shake, shakeSensitivity, modifier, hotkey, clipboardHotkey, reopenHotkey, keepAfterDragOut, ignoreApps }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        shake = try c.value(.shake, d.shake)
        shakeSensitivity = try c.value(.shakeSensitivity, d.shakeSensitivity)
        modifier = try c.value(.modifier, d.modifier)
        hotkey = try c.value(.hotkey, d.hotkey)
        clipboardHotkey = try c.value(.clipboardHotkey, d.clipboardHotkey)
        reopenHotkey = try c.value(.reopenHotkey, d.reopenHotkey)
        keepAfterDragOut = try c.value(.keepAfterDragOut, d.keepAfterDragOut)
        ignoreApps = try c.value(.ignoreApps, d.ignoreApps)
    }
}

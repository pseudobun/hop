import Foundation

nonisolated extension HopConfig {
    nonisolated struct Clipboard: PluginConfig {
        static let key = "clipboard"
        var enabled = true
        var hotkey = "shift+alt+c"
        /// Days to keep unpinned entries; -1 keeps them forever.
        var keepDays = 90
        var maxItems = 2000
        /// Keep copied images (stored as PNG next to the history).
        var images = true
        /// Larger images are not kept.
        var maxImageMB = 20
        /// Apps whose copies are never recorded (bundle identifiers).
        var ignoreApps = ["com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
                          "com.1password.1password", "com.bitwarden.desktop"]
        /// ↵ pastes into the app you were in; false only copies.
        var pasteOnReturn = true
        /// Let `hop clip` read the history (for agents); it can hold anything you copied.
        var cliAccess = false
    }

    var clipboard: Clipboard {
        get { sections[Clipboard.self] }
        set { sections[Clipboard.self] = newValue }
    }
}

nonisolated extension HopConfig.Clipboard {
    private enum Keys: String, CodingKey { case enabled, hotkey, keepDays, maxItems, images, maxImageMB, ignoreApps, pasteOnReturn, cliAccess }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        hotkey = try c.value(.hotkey, d.hotkey)
        keepDays = try c.value(.keepDays, d.keepDays)
        maxItems = try c.value(.maxItems, d.maxItems)
        images = try c.value(.images, d.images)
        maxImageMB = try c.value(.maxImageMB, d.maxImageMB)
        ignoreApps = try c.value(.ignoreApps, d.ignoreApps)
        pasteOnReturn = try c.value(.pasteOnReturn, d.pasteOnReturn)
        cliAccess = try c.value(.cliAccess, d.cliAccess)
    }
}

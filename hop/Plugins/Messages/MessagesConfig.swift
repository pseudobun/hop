import Foundation

nonisolated extension HopConfig {
    nonisolated struct Messages: PluginConfig {
        static let key = "messages"
        var enabled = true
        /// How far back "Messages Codes" looks.
        var days = 3
        /// "Paste Latest Code" only takes a code this recent.
        var latestMinutes = 15
        /// A HUD when a new code arrives.
        var notify = true
        /// Global hotkey for "Paste Latest Code"; "" turns it off.
        var pasteHotkey = "alt+cmd+v"
        /// Put a new code on the clipboard (concealed, cleared after two minutes).
        var autoCopy = false
    }

    var messages: Messages {
        get { sections[Messages.self] }
        set { sections[Messages.self] = newValue }
    }
}

nonisolated extension HopConfig.Messages {
    private enum Keys: String, CodingKey { case enabled, days, latestMinutes, notify, pasteHotkey, autoCopy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        days = try c.value(.days, d.days)
        latestMinutes = try c.value(.latestMinutes, d.latestMinutes)
        notify = try c.value(.notify, d.notify)
        pasteHotkey = try c.value(.pasteHotkey, d.pasteHotkey)
        autoCopy = try c.value(.autoCopy, d.autoCopy)
    }
}

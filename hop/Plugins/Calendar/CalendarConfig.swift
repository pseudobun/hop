import Foundation

nonisolated extension HopConfig {
    nonisolated struct CalendarSettings: PluginConfig {
        static let key = "calendar"
        var enabled = true
        /// Root search shows events starting within this many minutes (and ones running now).
        var soonMinutes = 60
        /// How many days "Calendar" lists.
        var days = 7
        /// Today's and tomorrow's birthdays at the top of root search.
        var birthdays = true
        /// Calendars to leave out, by name.
        var ignoreCalendars: [String] = []
    }

    var calendar: CalendarSettings {
        get { sections[CalendarSettings.self] }
        set { sections[CalendarSettings.self] = newValue }
    }
}

nonisolated extension HopConfig.CalendarSettings {
    private enum Keys: String, CodingKey { case enabled, soonMinutes, days, birthdays, ignoreCalendars }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        soonMinutes = try c.value(.soonMinutes, d.soonMinutes)
        days = try c.value(.days, d.days)
        birthdays = try c.value(.birthdays, d.birthdays)
        ignoreCalendars = try c.value(.ignoreCalendars, d.ignoreCalendars)
    }
}

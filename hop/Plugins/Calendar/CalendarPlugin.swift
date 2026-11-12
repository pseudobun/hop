import AppKit

/// Upcoming events and birthdays at the top of root search, and a Calendar list.
final class CalendarPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "calendar", name: "Calendar", summary: "Upcoming events and birthdays.", symbol: "calendar",
                   color: Palette.calendar, category: .integrations, enabledPath: ["calendar", "enabled"])
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("calendar.enabled", "Calendar", .toggle, "Asks for Calendar access."),
                .setting("calendar.soonMinutes", "Show events within", .number(min: 0, max: 1_440, unit: "min"),
                  "Root search shows events starting this soon, and ones running now."),
                .setting("calendar.days", "\"Calendar\" lists", .number(min: 1, max: 365, unit: "days")),
                .setting("calendar.birthdays", "Birthdays", .toggle, "Today's and tomorrow's at the top of root search."),
                .setting("calendar.ignoreCalendars", "Leave out", .list(placeholder: "Holidays"), "Calendar names, comma-separated."),
            ]),
        ]
    }

    init() {}

    private(set) var controller: CalendarController!
    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        controller = CalendarController(settings: host.settings)
        controller.onChange = { [weak host] in
            guard let host, host.launcher.isVisible, host.launcher.query.isEmpty else { return }
            host.launcher.reload()
        }
    }

    func apply(_ config: HopConfig, previous: HopConfig?, enabled: Bool) {
        if previous?.calendar != config.calendar { controller.apply(config.calendar) }
    }

    func commands() -> [Item] { CalendarCommands.items(host!.services) }
    func upcomingItems() -> [Item] { controller.upcomingItems() }
    func launcherWillShow() { controller.launcherWillShow() }
    func setAway(_ away: Bool) { controller.isPaused = away }
}

extension Services {
    var calendar: CalendarController? { plugin(CalendarPlugin.self)?.controller }
}

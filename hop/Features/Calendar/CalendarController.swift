import AppKit
import EventKit

/// Keeps the next few days of events at hand so root search can show what's coming
/// without waiting on EventKit.
final class CalendarController {
    private let settings: AppSettings
    private var config: HopConfig.CalendarSettings { settings.data.calendar }
    private(set) var events: [CalendarEvent] = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var loading = false
    /// The cached events changed.
    var onChange: (() -> Void)?

    init(settings: AppSettings) { self.settings = settings }

    func apply(_ config: HopConfig.CalendarSettings) {
        guard config.enabled else {
            timer?.invalidate()
            timer = nil
            events = []
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            }
        }
        if CalendarEvents.isUndetermined {
            // Asked once, at the first launch with the feature on.
            Task {
                if await CalendarEvents.requestAccess() { refresh() }
            }
        }
        refresh()
    }

    /// Re-reads events; await the task to know they are in.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard config.enabled, CalendarEvents.isAuthorized, !loading else { return nil }
        loading = true
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let end = start.addingTimeInterval(Double(max(2, config.days + 1)) * 86400)
        let ignored = Set(config.ignoreCalendars)
        return Task {
            let fresh = await CalendarEvents.events(from: start, to: end, ignoring: ignored)
            loading = false
            guard fresh != events else { return }
            events = fresh
            onChange?()
        }
    }

    /// Root's "Upcoming" rows: events running now or starting soon, then today's and tomorrow's birthdays.
    func upcomingItems(now: Date = Date()) -> [Item] {
        guard config.enabled else { return [] }
        var items = CalendarEvents.soon(events, now: now, minutes: config.soonMinutes).prefix(3).map { CalendarItems.event($0, now: now) }
        if config.birthdays {
            let b = CalendarEvents.birthdays(events, now: now)
            items += b.today.map { CalendarItems.birthday($0, today: true) }
            items += b.tomorrow.map { CalendarItems.birthday($0, today: false) }
        }
        return items
    }
}

/// Rows for events, shared by root and the Calendar mode.
enum CalendarItems {
    static func color(_ e: CalendarEvent) -> NSColor {
        e.color.count == 3 ? NSColor(srgbRed: e.color[0], green: e.color[1], blue: e.color[2], alpha: 1) : Palette.calendar
    }

    static func event(_ e: CalendarEvent, now: Date, showDay: Bool = false) -> Item {
        let ongoing = e.isOngoing(at: now)
        var detail = [CalendarEvents.timeRange(e), e.calendar]
        if !e.location.isEmpty, e.joinURL == nil { detail.insert(e.location, at: 1) }
        if showDay { detail.insert(day(e.start, now: now), at: 0) }
        let soon = !e.isAllDay && e.start > now && e.start.timeIntervalSince(now) < 2 * 3600
        let chip: Chip? = ongoing && !e.isAllDay ? Chip(text: "Now", tone: .good)
            : soon ? Chip(text: CalendarEvents.relative(e, now: now), tone: .info) : nil
        return Item(id: "calendar.\(e.id).\(e.start.timeIntervalSince1970)", title: e.title,
                    subtitle: detail.filter { !$0.isEmpty }.joined(separator: " · "),
                    icon: .tile(e.joinURL == nil ? "calendar" : "video.fill", color(e)),
                    accessory: e.joinURL == nil ? nil : "Join",
                    actions: actions(e), tracksFrecency: false, chip: chip)
    }

    /// One person's birthday, e.g. "Ana Novak" · Birthday today.
    static func birthday(_ e: CalendarEvent, today: Bool) -> Item {
        Item(id: "calendar.birthday.\(e.id).\(e.start.timeIntervalSince1970)", title: CalendarEvents.birthdayName(e.title),
             subtitle: today ? "Birthday today" : "Birthday tomorrow", icon: .emoji("🎂"),
             actions: [Action(title: "Open in Calendar", symbol: "calendar") {
                 open(e)
                 return .dismiss
             }], tracksFrecency: false,
             chip: Chip(text: today ? "Today" : "Tomorrow", tone: today ? .good : .info))
    }

    private static func actions(_ e: CalendarEvent) -> [Action] {
        var list: [Action] = []
        if let url = e.joinURL {
            list.append(Action(title: "Join Call", symbol: "video") {
                NSWorkspace.shared.open(url)
                return .dismiss
            })
        }
        list.append(Action(title: "Open in Calendar", symbol: "calendar", shortcut: e.joinURL == nil ? nil : .ret(.command)) {
            open(e)
            return .dismiss
        })
        if let url = e.joinURL {
            list.append(Action(title: "Copy Call Link", shortcut: .cmd("c")) {
                Pasteboard.copy(url.absoluteString)
                return .dismissWithHUD("Copied call link")
            })
        }
        return list
    }

    /// Calendar.app at the event's day; `ical://ekevent/` selects the event itself.
    static func open(_ e: CalendarEvent) {
        let id = e.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? e.id
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// "Today", "Tomorrow", "Friday", "3 Nov".
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return "Tomorrow" }
        let f = DateFormatter()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        f.setLocalizedDateFormatFromTemplate(days > 0 && days < 7 ? "EEEE" : "d MMM")
        return f.string(from: date)
    }
}

/// Root command and the "Calendar" sub-mode.
enum CalendarCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.calendar
        guard config.enabled, let calendar = services.calendar else { return [] }
        return [
            Item(id: "calendar.upcoming", title: "Calendar", subtitle: "Upcoming events and birthdays, join calls",
                 aliases: ["events", "meetings", "agenda", "koledar"], icon: .tile("calendar", Palette.calendar), accessory: "Command",
                 actions: [Action(title: "Show Upcoming Events", symbol: "calendar") {
                     .push(CalendarMode(controller: calendar, days: config.days, sensitivity: services.settings.data.general.sensitivity))
                 }], pushesMode: true),
        ]
    }
}

final class CalendarMode: Mode {
    let title: String? = "Calendar"
    let tint: NSColor? = Palette.calendar
    let placeholder = "Search events…"
    private let controller: CalendarController
    private let days: Int
    private let sensitivity: Sensitivity
    private weak var context: LauncherContext?
    private var denied = false

    init(controller: CalendarController, days: Int, sensitivity: Sensitivity) {
        self.controller = controller
        self.days = days
        self.sensitivity = sensitivity
    }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        Task {
            if !CalendarEvents.isAuthorized {
                guard CalendarEvents.isUndetermined else {
                    denied = true
                    return context.reload()
                }
                context.suppressAutoHide = true
                let granted = await CalendarEvents.requestAccess()
                context.suppressAutoHide = false
                denied = !granted
            }
            await controller.refresh()?.value
            self.context?.reload()
        }
    }

    func sections(for query: String) -> [ResultSection] {
        if denied {
            return [ResultSection(title: nil, items: [Item(
                id: "calendar.access", title: "Allow Calendar Access", subtitle: "hop shows upcoming events and birthdays",
                icon: .tile("calendar", Theme.warn), accessory: "System Settings",
                actions: [Action(title: "Open System Settings", symbol: "gearshape") {
                    NSWorkspace.shared.open(Permission.calendar.settingsURL)
                    return .dismiss
                }], tracksFrecency: false)])]
        }
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(days + 1) * 86400)
        var list = controller.events.filter { $0.end > now && $0.start < end }
        if !query.isEmpty {
            let cands = list.map { RankCandidate(id: $0.id, title: $0.title, subtitle: "\($0.calendar) \($0.location)", typeWeight: 1) }
            let items = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity)
                .map { CalendarItems.event(list[$0], now: now, showDay: true) }
            return [ResultSection(title: "Events", items: items)]
        }
        if list.isEmpty {
            return [ResultSection(title: nil, items: [Item(
                id: "calendar.none", title: "Nothing in the next \(days) days", icon: .symbol("calendar"),
                actions: [], tracksFrecency: false)])]
        }
        // Day sections, all-day events and birthdays first.
        list.sort { ($0.start < now ? now : $0.start, $0.isAllDay ? 0 : 1) < ($1.start < now ? now : $1.start, $1.isAllDay ? 0 : 1) }
        var sections: [ResultSection] = []
        let cal = Calendar.current
        for (_, group) in Dictionary(grouping: list, by: { cal.startOfDay(for: max($0.start, now)) }).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
            let items = ordered.map { e in
                e.isBirthday ? CalendarItems.birthday(e, today: true).with(id: "calendar.\(e.id)", subtitle: "Birthday")
                    : CalendarItems.event(e, now: now)
            }
            sections.append(ResultSection(title: CalendarItems.day(max(group[0].start, now), now: now), items: items))
        }
        return sections
    }
}

private extension Item {
    func with(id: String, subtitle: String) -> Item {
        Item(id: id, title: title, subtitle: subtitle, icon: icon, actions: actions, tracksFrecency: false)
    }
}

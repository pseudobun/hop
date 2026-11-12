import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Calendar plugin.
extension CalendarPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["events"], usage: [
                "events [--days=N] [--birthdays] [--json]  Calendar events from today on (default today only)",
            ], run: CLI.events),
        ]
    }
}

extension CLI {
    /// `hop events [--days=N] [--birthdays]`: today's and the next days' events.
    static func events(_ a: Args) async -> Int32 {
        let config = AppSettings().data.calendar
        let days = max(1, a.option("days").flatMap(Int.init) ?? 1)
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(Double(days) * 86400)
        var list: [CalendarEvent]
        if await CalendarEvents.status() == .fullAccess {
            list = await CalendarEvents.events(from: start, to: end, ignoring: Set(config.ignoreCalendars))
        } else if let cached = CalendarController.cache.load() {
            // What the running hop read last (it has access; this terminal may not).
            list = cached.filter { $0.end > start && $0.start < end }
            if days > config.days + 1 { FileHandle.standardError.write(Data("hop: only the next \(config.days) days are cached\n".utf8)) }
        } else {
            return Output.fail("no Calendar access here and no events from the running hop yet (is hop running with Calendar access?)")
        }
        if !a.flags.contains("birthdays") { list.removeAll(where: \.isBirthday) }
        if a.json {
            Output.json(list.map { e -> [String: Any] in
                ["title": e.title, "start": iso.string(from: e.start), "end": iso.string(from: e.end), "allDay": e.isAllDay,
                 "birthday": e.isBirthday, "calendar": e.calendar, "location": e.location, "joinURL": e.joinURL?.absoluteString ?? ""]
            })
        } else {
            let f = DateFormatter()
            f.dateFormat = "EEE d.M. HH:mm"
            for e in list {
                let when = e.isAllDay ? "all day \(CalendarItems.day(e.start, now: Date()))" : "\(f.string(from: e.start))–\(CalendarEvents.timeRange(e).split(separator: "–").last ?? "")"
                print([when, e.title, e.calendar, e.joinURL?.absoluteString ?? e.location].joined(separator: "\t"))
            }
        }
        return 0
    }
}

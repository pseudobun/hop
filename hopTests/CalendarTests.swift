import Foundation
import Testing
@testable import hop

struct CalendarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, in minutes: Double, for length: Double = 30, allDay: Bool = false, birthday: Bool = false) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(id: title, title: title, start: start, end: start.addingTimeInterval(length * 60), isAllDay: allDay,
                             isBirthday: birthday, calendar: "Work", color: [], location: "", joinURL: nil)
    }

    @Test func findsCallLinks() {
        #expect(CalendarEvents.joinURL(in: ["Join: https://meet.google.com/abc-defg-hij"])?.host() == "meet.google.com")
        #expect(CalendarEvents.joinURL(in: ["", "<https://us02web.zoom.us/j/123?pwd=x>"])?.absoluteString == "https://us02web.zoom.us/j/123?pwd=x")
        #expect(CalendarEvents.joinURL(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting"]) != nil)
        #expect(CalendarEvents.joinURL(in: ["https://example.com/zoom.us", "Room 4"]) == nil)
        #expect(CalendarEvents.joinURL(in: ["https://notzoom.us/j/1"]) == nil)
    }

    @Test func soonKeepsRunningAndUpcomingTimedEvents() {
        let events = [event("past", in: -60), event("running", in: -10), event("soon", in: 20), event("later", in: 120),
                      event("allday", in: 5, allDay: true), event("Ana", in: 5, birthday: true)]
        #expect(CalendarEvents.soon(events, now: now, minutes: 60).map(\.title) == ["running", "soon"])
    }

    @Test func birthdaysTodayAndTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: now)
        let make = { (title: String, day: Double) in
            CalendarEvent(id: title, title: title, start: today.addingTimeInterval(day * 86400), end: today.addingTimeInterval((day + 1) * 86400),
                          isAllDay: true, isBirthday: true, calendar: "Birthdays", color: [], location: "", joinURL: nil)
        }
        let b = CalendarEvents.birthdays([make("Ana", 0), make("Bor", 1), make("Cene", 2)], now: now, calendar: cal)
        #expect(b.today.map(\.title) == ["Ana"])
        #expect(b.tomorrow.map(\.title) == ["Bor"])
    }

    @Test func birthdayNames() {
        #expect(CalendarEvents.birthdayName("Ana Novak’s Birthday") == "Ana Novak")
        #expect(CalendarEvents.birthdayName("Jonas' Birthday") == "Jonas")
        #expect(CalendarEvents.birthdayName("Rojstni dan: Bor") == "Rojstni dan: Bor")
    }

    @Test func relativeTimes() {
        #expect(CalendarEvents.relative(event("a", in: -5), now: now) == "now")
        #expect(CalendarEvents.relative(event("a", in: 12), now: now) == "in 12 min")
        #expect(CalendarEvents.relative(event("a", in: 60), now: now) == "in 1 h")
        #expect(CalendarEvents.relative(event("a", in: 65), now: now) == "in 1 h 5 min")
    }

    @Test func configDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let config = try decoder.decode(HopConfig.self, from: Data("{calendar: {soonMinutes: 30}, messages: {enabled: false}}".utf8))
        #expect(config.calendar.soonMinutes == 30 && config.calendar.birthdays && config.calendar.days == 7)
        #expect(!config.messages.enabled && config.messages.latestMinutes == 15)
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.calendar == HopConfig.CalendarSettings() && template.messages == HopConfig.Messages())
    }
}

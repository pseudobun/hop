import AppKit
import EventKit

/// One calendar event, copied out of EventKit so it can cross threads.
nonisolated struct CalendarEvent: Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isBirthday: Bool
    let calendar: String
    /// The calendar's colour as sRGB components.
    let color: [Double]
    let location: String
    /// A Meet, Zoom, Teams, Webex or FaceTime link from the URL, location or notes.
    let joinURL: URL?

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
}

/// Reads events from Calendar (EventKit). All EventKit work runs on one serial queue.
nonisolated enum CalendarEvents {
    private static let queue = DispatchQueue(label: "hop.calendar", qos: .userInitiated)
    /// Only touched on `queue`.
    private final class StoreBox: @unchecked Sendable { var store = EKEventStore() }
    private static let box = StoreBox()

    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var isUndetermined: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    /// Shows the macOS prompt once; true when access is granted.
    static func requestAccess() async -> Bool {
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        // A store made before access was granted never sees events.
        if granted { queue.sync { box.store = EKEventStore() } }
        return granted
    }

    /// Events overlapping `from..<to`, sorted by start.
    static func events(from: Date, to: Date, ignoring ignored: Set<String> = []) async -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        return await withCheckedContinuation { done in
            queue.async {
                let store = box.store
                let calendars = store.calendars(for: .event).filter { !ignored.contains($0.title) }
                guard !calendars.isEmpty else { return done.resume(returning: []) }
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
                let events = store.events(matching: predicate).map(convert).sorted { $0.start < $1.start }
                done.resume(returning: events)
            }
        }
    }

    private static func convert(_ e: EKEvent) -> CalendarEvent {
        let rgb = e.calendar?.cgColor.flatMap { $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) }
        return CalendarEvent(
            id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled", start: e.startDate, end: e.endDate,
            isAllDay: e.isAllDay, isBirthday: e.calendar?.type == .birthday, calendar: e.calendar?.title ?? "",
            color: rgb?.components?.prefix(3).map(Double.init) ?? [], location: e.location ?? "",
            joinURL: joinURL(in: [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }))
    }

    // MARK: - Join links

    private static let joinHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
                                    "webex.com", "facetime.apple.com", "whereby.com", "meet.jit.si", "around.co"]
    private static let link = try! NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)

    /// The first video-call link in these texts.
    static func joinURL(in texts: [String]) -> URL? {
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for m in link.matches(in: text, range: range) {
                guard let r = Range(m.range, in: text), let url = URL(string: String(text[r])),
                      let host = url.host()?.lowercased() else { continue }
                if joinHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    // MARK: - What root shows

    /// Timed events running now or starting within `minutes`, soonest first.
    static func soon(_ events: [CalendarEvent], now: Date, minutes: Int) -> [CalendarEvent] {
        events.filter { e in
            !e.isAllDay && !e.isBirthday && e.end > now && e.start <= now.addingTimeInterval(Double(minutes) * 60)
        }
    }

    /// Birthdays today and tomorrow.
    static func birthdays(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> (today: [CalendarEvent], tomorrow: [CalendarEvent]) {
        let all = events.filter(\.isBirthday)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        return (all.filter { calendar.isDate($0.start, inSameDayAs: now) },
                all.filter { calendar.isDate($0.start, inSameDayAs: tomorrow) })
    }

    /// "in 12 min", "now", "in 1 h 5 min".
    static func relative(_ e: CalendarEvent, now: Date) -> String {
        if e.isOngoing(at: now) { return "now" }
        let minutes = max(1, Int((e.start.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }

    /// "10:30–11:00", or "All day".
    static func timeRange(_ e: CalendarEvent) -> String {
        if e.isAllDay { return "All day" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(f.string(from: e.start))–\(f.string(from: e.end))"
    }
}

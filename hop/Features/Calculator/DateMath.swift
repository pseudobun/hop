import Foundation

/// Dates and durations: "tomorrow", "in 3 weeks", "3 days ago", "next friday",
/// "24.12. + 30 days", "days until christmas", "days since 1.1.2026", "2026-12-24 - today",
/// "week number"; a few in Slovenian ("jutri", "čez 3 tedne", "pred 2 dnevoma").
nonisolated enum DateMath {
    enum Answer: Equatable {
        /// A day (and whether a time of day matters).
        case date(Date, withTime: Bool)
        /// Whole days between two dates (positive = the second is later).
        case days(Int, from: Date, to: Date)
        case week(Int, year: Int)
    }

    private static let units: [(names: [String], component: Calendar.Component, factor: Int)] = [
        (["minute", "minutes", "min", "mins", "minuta", "minut", "minute"], .minute, 1),
        (["hour", "hours", "h", "hr", "hrs", "ura", "uri", "ure", "ur"], .hour, 1),
        (["day", "days", "d", "dan", "dni", "dneva", "dnevi", "dnevoma", "dnevi"], .day, 1),
        (["week", "weeks", "w", "wk", "teden", "tedna", "tedne", "tednov", "tednoma"], .day, 7),
        (["month", "months", "mo", "mesec", "meseca", "mesece", "mesecev"], .month, 1),
        (["year", "years", "y", "yr", "leto", "leti", "leta", "let"], .year, 1),
    ]

    private static func unit(_ word: String) -> (Calendar.Component, Int)? {
        units.first { $0.names.contains(word) }.map { ($0.component, $0.factor) }
    }

    private static let weekdays: [[String]] = [
        ["sunday", "sun", "nedelja", "nedeljo"], ["monday", "mon", "ponedeljek"], ["tuesday", "tue", "tues", "torek"],
        ["wednesday", "wed", "sreda", "sredo"], ["thursday", "thu", "thurs", "četrtek"], ["friday", "fri", "petek"],
        ["saturday", "sat", "sobota", "soboto"],
    ]

    private static let months: [[String]] = [
        ["january", "jan", "januar"], ["february", "feb", "februar"], ["march", "mar", "marec"], ["april", "apr"],
        ["may", "maj"], ["june", "jun", "junij"], ["july", "jul", "julij"], ["august", "aug", "avgust", "avg"],
        ["september", "sep", "sept"], ["october", "oct", "oktober", "okt"], ["november", "nov"], ["december", "dec"],
    ]

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Answer? {
        var q = input.trimmingCharacters(in: .whitespaces).lowercased()
        while q.hasSuffix("?") { q.removeLast() }
        guard q.count >= 3, q.count < 80 else { return nil }
        let today = calendar.startOfDay(for: now)

        if ["week number", "week", "current week", "teden", "kateri teden"].contains(q) {
            return .week(calendar.component(.weekOfYear, from: now), year: calendar.component(.yearForWeekOfYear, from: now))
        }
        // days until / since / between
        if let m = q.wholeMatch(of: /(?:days|dni)\s+(?:until|till|to|do)\s+(.+)/), let d = day(String(m.1), now: now, calendar: calendar) {
            return .days(days(today, d, calendar), from: today, to: d)
        }
        if let m = q.wholeMatch(of: /(?:days|dni)\s+(?:since|from|od)\s+(.+)/), let d = day(String(m.1), now: now, calendar: calendar) {
            return .days(days(d, today, calendar), from: d, to: today)
        }
        // <date> - <date>
        if let m = q.wholeMatch(of: /(.+?)\s+-\s+(.+)/), let a = day(String(m.1), now: now, calendar: calendar),
           let b = day(String(m.2), now: now, calendar: calendar) {
            return .days(days(b, a, calendar), from: b, to: a)
        }
        // <date> +/- N unit
        if let m = q.wholeMatch(of: /(.+?)\s*([+-])\s*(\d+)\s*([a-zčšž]+)/), let base = day(String(m.1), now: now, calendar: calendar),
           let n = Int(m.3), let (component, factor) = unit(String(m.4)) {
            let sign = m.2 == "-" ? -1 : 1
            guard let d = calendar.date(byAdding: component, value: sign * n * factor, to: base) else { return nil }
            return .date(d, withTime: component == .hour || component == .minute)
        }
        // in N unit / N unit from now / čez N enot
        if let m = q.wholeMatch(of: /(?:in|čez|cez)\s+(\d+)\s*([a-zčšž]+)/) ?? q.wholeMatch(of: /(\d+)\s*([a-zčšž]+)\s+from now/),
           let n = Int(m.1), let (component, factor) = unit(String(m.2)) {
            guard let d = calendar.date(byAdding: component, value: n * factor, to: now) else { return nil }
            return .date(d, withTime: component == .hour || component == .minute)
        }
        // N unit ago / pred N enot
        if let m = q.wholeMatch(of: /(\d+)\s*([a-zčšž]+)\s+ago/) ?? q.wholeMatch(of: /pred\s+(\d+)\s*([a-zčšž]+)/),
           let n = Int(m.1), let (component, factor) = unit(String(m.2)) {
            guard let d = calendar.date(byAdding: component, value: -n * factor, to: now) else { return nil }
            return .date(d, withTime: component == .hour || component == .minute)
        }
        // A date on its own (named days are worth showing; bare numbers are not dates).
        if let d = day(q, now: now, calendar: calendar), q.contains(where: \.isLetter) || q.filter({ $0 == "." || $0 == "-" || $0 == "/" }).count >= 2 {
            return .date(d, withTime: false)
        }
        return nil
    }

    private static func days(_ a: Date, _ b: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }

    /// One day: named ("today", "next friday", "christmas") or written ("24.12.", "2026-12-24", "dec 24", "24 december 2026").
    static func day(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        func nextOccurrence(month: Int, day: Int) -> Date? {
            guard var d = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            if d < today { d = calendar.date(from: DateComponents(year: year + 1, month: month, day: day)) ?? d }
            return d
        }
        switch s {
        case "today", "now", "danes": return today
        case "tomorrow", "jutri": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday", "včeraj", "vceraj": return calendar.date(byAdding: .day, value: -1, to: today)
        case "christmas", "xmas", "božič", "bozic": return nextOccurrence(month: 12, day: 25)
        case "christmas eve", "božični večer": return nextOccurrence(month: 12, day: 24)
        case "new year", "new year's day", "new years", "novo leto": return calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        case "new year's eve", "silvestrovo": return nextOccurrence(month: 12, day: 31)
        case "halloween": return nextOccurrence(month: 10, day: 31)
        case "valentine's day", "valentines day", "valentinovo": return nextOccurrence(month: 2, day: 14)
        default: break
        }
        // (next|last|this) <weekday>, or a bare weekday (the next one)
        if let m = s.wholeMatch(of: /(?:(next|last|this|naslednji|naslednjo|prejšnji|prejšnjo|ta|to)\s+)?([a-zčšž]+)/),
           let wd = weekdays.firstIndex(where: { $0.contains(String(m.2)) }) {
            let current = calendar.component(.weekday, from: today) - 1
            var delta = (wd - current + 7) % 7
            switch m.1.map(String.init) {
            case "last", "prejšnji", "prejšnjo": delta = delta == 0 ? -7 : delta - 7
            case "next", "naslednji", "naslednjo": if delta == 0 { delta = 7 }
            default: break
            }
            return calendar.date(byAdding: .day, value: delta, to: today)
        }
        // 2026-12-24
        if let m = s.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/) {
            return calendar.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3)))
        }
        // 24.12.2026, 24.12., 24/12/2026 (day first, as in Slovenia)
        if let m = s.wholeMatch(of: /(\d{1,2})[.\/](\d{1,2})[.\/]?(\d{2,4})?\.?/), let d = Int(m.1), let mo = Int(m.2),
           (1...31).contains(d), (1...12).contains(mo) {
            if let y = m.3.flatMap({ Int($0) }) {
                return calendar.date(from: DateComponents(year: y < 100 ? 2000 + y : y, month: mo, day: d))
            }
            return nextOccurrence(month: mo, day: d)
        }
        // 24 dec [2026], dec 24 [2026], 24. december
        let words = s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ".", with: " ")
            .split(separator: " ").map(String.init)
        if words.count >= 2, words.count <= 3 {
            var dayNumber: Int?, month: Int?, yearNumber: Int?
            for w in words {
                if let n = Int(w) {
                    if n > 31 { yearNumber = n } else if dayNumber == nil { dayNumber = n } else { yearNumber = n }
                } else if let i = months.firstIndex(where: { $0.contains(w) }) {
                    month = i + 1
                } else {
                    return nil
                }
            }
            if let d = dayNumber, let mo = month, (1...31).contains(d) {
                if let y = yearNumber { return calendar.date(from: DateComponents(year: y, month: mo, day: d)) }
                return nextOccurrence(month: mo, day: d)
            }
        }
        return nil
    }

    /// "Sat, 24 Oct 2026" (with the time when it matters).
    static func format(_ date: Date, withTime: Bool, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(withTime ? "EEEdMMMyjmm" : "EEEdMMMy")
        return f.string(from: date)
    }

    /// "24 Oct", or "24 Oct 2027" outside the current year.
    static func short(_ date: Date, now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMy")
        return f.string(from: date)
    }

    /// "in 5 days", "3 days ago", "today".
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch d {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let n where n > 0: return "in \(n) days"
        default: return "\(-d) days ago"
        }
    }

    /// "61 days" → "8 weeks 5 days".
    static func weeksAndDays(_ days: Int) -> String {
        let n = abs(days)
        guard n >= 7 else { return n == 1 ? "1 day" : "\(n) days" }
        let w = n / 7, r = n % 7
        return "\(w) week\(w == 1 ? "" : "s")" + (r > 0 ? " \(r) day\(r == 1 ? "" : "s")" : "")
    }
}

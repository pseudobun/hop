import Foundation

/// "time in tokyo", "tokyo time", "5pm london in ljubljana", "14:00 cet to pst", "3pm tokyo".
nonisolated enum TimeZones {
    struct Answer: Equatable {
        let from: Date
        let fromZone: TimeZone
        let fromName: String
        let toZone: TimeZone
        let toName: String
    }

    private static let aliases: [String: String] = [
        "ny": "America/New_York", "nyc": "America/New_York", "new york city": "America/New_York", "boston": "America/New_York",
        "washington": "America/New_York", "dc": "America/New_York", "miami": "America/New_York", "atlanta": "America/New_York",
        "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "silicon valley": "America/Los_Angeles", "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
        "pt": "America/Los_Angeles", "pacific": "America/Los_Angeles", "et": "America/New_York", "eastern": "America/New_York",
        "ct": "America/Chicago", "central": "America/Chicago", "mt": "America/Denver", "mountain": "America/Denver",
        "uk": "Europe/London", "england": "Europe/London", "britain": "Europe/London", "slovenia": "Europe/Ljubljana",
        "slovenija": "Europe/Ljubljana", "germany": "Europe/Berlin", "nemčija": "Europe/Berlin", "france": "Europe/Paris",
        "spain": "Europe/Madrid", "italy": "Europe/Rome", "croatia": "Europe/Zagreb", "hrvaška": "Europe/Zagreb", "austria": "Europe/Vienna",
        "avstrija": "Europe/Vienna", "serbia": "Europe/Belgrade", "srbija": "Europe/Belgrade", "japan": "Asia/Tokyo", "japonska": "Asia/Tokyo",
        "china": "Asia/Shanghai", "kitajska": "Asia/Shanghai", "beijing": "Asia/Shanghai", "peking": "Asia/Shanghai",
        "india": "Asia/Kolkata", "indija": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "hk": "Asia/Hong_Kong", "sg": "Asia/Singapore", "dubai": "Asia/Dubai", "uae": "Asia/Dubai", "australia": "Australia/Sydney",
        "brazil": "America/Sao_Paulo", "canada": "America/Toronto", "mexico": "America/Mexico_City", "korea": "Asia/Seoul",
        "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem", "turkey": "Europe/Istanbul", "russia": "Europe/Moscow",
        "tokio": "Asia/Tokyo", "dunaj": "Europe/Vienna", "pariz": "Europe/Paris", "rim": "Europe/Rome", "beograd": "Europe/Belgrade",
        "moskva": "Europe/Moscow", "london": "Europe/London", "berlin": "Europe/Berlin", "munich": "Europe/Berlin", "münchen": "Europe/Berlin",
        "zurich": "Europe/Zurich", "zürich": "Europe/Zurich", "amsterdam": "Europe/Amsterdam", "utc": "UTC", "gmt": "GMT", "z": "UTC",
        "here": "", "local": "", "tu": "",
    ]

    /// City names from the IANA identifiers: "new york" → America/New_York.
    private static let cities: [String: String] = {
        var m: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let city = id.split(separator: "/").last else { continue }
            m[city.replacingOccurrences(of: "_", with: " ").lowercased()] = id
        }
        return m
    }()

    /// A place, abbreviation ("cet", "pst") or "here".
    static func zone(_ raw: String, local: TimeZone) -> (TimeZone, String)? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        if let id = aliases[name] {
            if id.isEmpty { return (local, "Here") }
            return TimeZone(identifier: id).map { ($0, display(name, id: id)) }
        }
        if let id = cities[name], let tz = TimeZone(identifier: id) { return (tz, display(name, id: id)) }
        if name.count >= 3, name.count <= 5, name.allSatisfy(\.isLetter), let tz = TimeZone(abbreviation: name.uppercased()) {
            return (tz, name.uppercased())
        }
        return nil
    }

    private static func display(_ typed: String, id: String) -> String {
        if typed.count <= 3 || ["pacific", "eastern", "central", "mountain"].contains(typed) { return typed.uppercased() == typed ? typed : typed.capitalized }
        if typed == "utc" || typed == "gmt" { return typed.uppercased() }
        return typed.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "5pm", "5:30 pm", "17:00", "17h", "17.30", "noon", "midnight" → (hour, minute).
    static func clockTime(_ raw: String) -> (Int, Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        switch s {
        case "noon", "poldne": return (12, 0)
        case "midnight", "polnoč": return (0, 0)
        default: break
        }
        guard let m = s.wholeMatch(of: /(\d{1,2})(?:[:.](\d{2}))?(am|pm|a|p|h)?/) else { return nil }
        guard var h = Int(m.1) else { return nil }
        let minute = m.2.flatMap { Int($0) } ?? 0
        let suffix = m.3.map(String.init)
        if suffix == nil && m.2 == nil { return nil } // a bare number is not a time
        if let suffix, suffix.hasPrefix("a") || suffix.hasPrefix("p") {
            guard (1...12).contains(h) else { return nil }
            if suffix.hasPrefix("p") && h != 12 { h += 12 }
            if suffix.hasPrefix("a") && h == 12 { h = 0 }
        }
        guard (0...23).contains(h), (0...59).contains(minute) else { return nil }
        return (h, minute)
    }

    static func parse(_ input: String, now: Date = Date(), local: TimeZone = .current) -> Answer? {
        var q = input.trimmingCharacters(in: .whitespaces).lowercased()
        while q.hasSuffix("?") { q.removeLast() }
        guard q.count >= 3, q.count < 80 else { return nil }

        // time in tokyo / now in tokyo / ura v tokiu
        if let m = q.wholeMatch(of: /(?:what(?:'s| is) the )?(?:time|now|current time|ura|čas)\s+(?:in|v|at)\s+(.+)/),
           let (tz, name) = zone(String(m.1), local: local) {
            return Answer(from: now, fromZone: local, fromName: "Here", toZone: tz, toName: name)
        }
        // tokyo time
        if let m = q.wholeMatch(of: /(.+?)\s+time/), let (tz, name) = zone(String(m.1), local: local) {
            return Answer(from: now, fromZone: local, fromName: "Here", toZone: tz, toName: name)
        }
        // <time> [<place>] in|to|v <place>   or   <time> <place>
        let words = q.split(separator: " ").map(String.init)
        for timeWords in 1...min(2, words.count) {
            guard let (h, m) = clockTime(words.prefix(timeWords).joined(separator: " ")) else { continue }
            let rest = Array(words.dropFirst(timeWords))
            var fromPart = rest, toPart: [String] = []
            if let sep = rest.lastIndex(where: { ["in", "to", "v", "→", "->", "="].contains($0) }) {
                fromPart = Array(rest[..<sep])
                toPart = Array(rest[(sep + 1)...])
            }
            let from = fromPart.isEmpty ? (local, "Here") : zone(fromPart.joined(separator: " "), local: local)
            let to = toPart.isEmpty ? (fromPart.isEmpty ? nil : (local, "Here")) : zone(toPart.joined(separator: " "), local: local)
            guard let (fz, fn) = from, let (tz, tn) = to, fz.identifier != tz.identifier || fn != tn else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = fz
            var c = cal.dateComponents([.year, .month, .day], from: now)
            c.hour = h
            c.minute = m
            guard let date = cal.date(from: c) else { continue }
            return Answer(from: date, fromZone: fz, fromName: fn, toZone: tz, toName: tn)
        }
        return nil
    }

    static func clock(_ date: Date, _ zone: TimeZone, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }

    static func offset(_ zone: TimeZone, at date: Date) -> String {
        let s = zone.secondsFromGMT(for: date)
        let h = abs(s) / 3600, m = abs(s) % 3600 / 60
        return "UTC" + (s == 0 ? "" : (s < 0 ? "−" : "+") + "\(h)" + (m > 0 ? String(format: ":%02d", m) : ""))
    }

    /// Calendar-day difference of the same instant in two zones: +1 when `to` is a day ahead.
    static func dayShift(_ date: Date, from: TimeZone, to: TimeZone) -> Int {
        var a = Calendar(identifier: .gregorian), b = a
        a.timeZone = from
        b.timeZone = to
        let da = a.dateComponents([.year, .month, .day], from: date), db = b.dateComponents([.year, .month, .day], from: date)
        let ref = Calendar(identifier: .gregorian)
        guard let x = ref.date(from: da), let y = ref.date(from: db) else { return 0 }
        return ref.dateComponents([.day], from: x, to: y).day ?? 0
    }
}

import AppKit
import EventKit

/// CLI commands for the newer features: Messages codes, Calendar, translation, OCR,
/// emoji, bookmarks and permissions. Same conventions: tab-separated text, `--json`.
extension CLI {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `hop codes [--latest] [--minutes=N]`: one-time codes from Messages, newest first.
    static func codes(_ a: Args) async -> Int32 {
        let config = AppSettings().data.messages
        let latest = a.flags.contains("latest")
        let minutes = a.option("minutes").flatMap(Int.init) ?? (latest ? config.latestMinutes : config.days * 1440)
        switch await MessageCodes.recent(since: Date().addingTimeInterval(-Double(minutes) * 60)) {
        case .failure(.noAccess):
            return Output.fail("cannot read ~/Library/Messages: give the terminal (or hop) Full Disk Access")
        case .failure(.unreadable(let message)):
            return Output.fail("cannot read Messages: \(message)")
        case .success(let codes):
            let list = latest ? Array(codes.prefix(1)) : codes
            if latest && list.isEmpty { return Output.fail("no code in the last \(minutes) minutes") }
            if a.json {
                Output.json(list.map { ["code": $0.code, "sender": $0.sender, "date": iso.string(from: $0.date), "text": $0.text] })
            } else if latest {
                print(list[0].code)
            } else {
                for c in list { print("\(c.code)\t\(c.sender)\t\(iso.string(from: c.date))\t\(oneLine(c.text))") }
            }
            return 0
        }
    }

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

    /// `hop tr <text> [--to=CODE]` (or text on stdin): between the `translate.languages` with OpenAI.
    static func translate(_ a: Args) async -> Int32 {
        let text = (a.positional.isEmpty ? stdinInput() ?? "" : a.positional.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let config = AppSettings().data.translate
        let pair = Translator.Pair(config.languages)
        let codes = "\(pair.first.code)|\(pair.second.code)"
        guard !text.isEmpty else { return Output.fail("usage: hop tr <text> [--to=\(codes)], or text on stdin") }
        let target: Translator.Language
        if let raw = a.option("to") {
            guard let language = pair.language(named: raw) else { return Output.fail("--to must be \(codes), not \(raw)") }
            target = language
        } else {
            target = Translator.target(for: text, pair: pair)
        }
        switch await Translator.translate(text, to: target, pair: pair, model: config.model, reasoning: config.reasoning) {
        case .success(let translation):
            if a.json { Output.json(["text": text, "to": target.name, "translation": translation]) } else { print(translation) }
            return 0
        case .failure(let error):
            return Output.fail(OpenAI.describe(error))
        }
    }

    /// `hop ocr [image] [--copy]`: text in an image, or in an area you select on screen.
    static func ocr(_ a: Args) async -> Int32 {
        var url: URL
        var temporary = false
        if let path = a.positional.first {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return Output.fail("no such file: \(path)") }
        } else {
            guard let captured = await ScreenText.capture() else { return Output.fail("no area selected") }
            url = captured
            temporary = true
        }
        defer { if temporary { try? FileManager.default.removeItem(at: url) } }
        let lines = await ScreenText.recognize(url, languages: AppSettings().data.ocr.languages)
        guard !lines.isEmpty else { return Output.fail("no text found") }
        let text = lines.joined(separator: "\n")
        if a.flags.contains("copy") { Pasteboard.copy(text) }
        if a.json { Output.json(["lines": lines, "text": text]) } else { print(text) }
        return 0
    }

    /// `hop emoji <query> [--limit=N] [--json]`: the picker's search, slang and Slovenian included.
    static func emoji(_ a: Args) async -> Int32 {
        let query = a.positional.joined(separator: " ")
        guard !query.isEmpty else { return Output.fail("usage: hop emoji <query>") }
        guard let index = EmojiIndex.loadBlocking() else { return Output.fail("emoji data missing") }
        let tone = SkinTone(config: AppSettings().data.emoji.skinTone)
        let limit = a.option("limit").flatMap(Int.init) ?? 10
        let hits = index.search(query).prefix(limit).map { index.entries[$0] }
        if a.json {
            Output.json(hits.map { ["emoji": index.applying(tone, to: $0), "name": $0.name, "keywords": $0.keywords] })
        } else {
            for e in hits { print("\(index.applying(tone, to: e))\t\(e.name)") }
        }
        return hits.isEmpty ? 1 : 0
    }

    /// `hop bookmarks [query] [--json]`, `hop bookmarks open <name>`.
    static func bookmarks(_ a: Args) async -> Int32 {
        let all = AppSettings().data.bookmarks.compactMap { b in BookmarkCommands.url(b.url).map { (b, $0) } }
        var words = a.positional
        let open = words.first == "open"
        if open || words.first == "list" { words.removeFirst() }
        let query = words.joined(separator: " ").lowercased()
        let matches = query.isEmpty ? all : all.filter { b, _ in
            b.name.lowercased().contains(query) || b.aliases.contains { $0.lowercased() == query }
        }
        if open {
            guard let (b, url) = matches.first(where: { $0.0.name.lowercased() == query || $0.0.aliases.map { $0.lowercased() }.contains(query) })
                ?? matches.first else { return Output.fail("no bookmark matching \(query)") }
            NSWorkspace.shared.open(url)
            print("opened \(b.name)")
            return 0
        }
        if a.json {
            Output.json(matches.map { b, url in ["name": b.name, "url": url.absoluteString, "aliases": b.aliases] })
        } else {
            for (b, url) in matches { print("\(b.name)\t\(url.absoluteString)") }
        }
        return 0
    }

    /// `hop permissions [--json]`: what hop has been granted, as the Permissions screen shows it.
    static func permissions(_ a: Args) async -> Int32 {
        let rows = Permission.allCases.map { p -> (String, String, Bool) in
            let status = switch p.status() {
            case .granted: "granted"
            case .missing: "missing"
            case .unknown: "not asked"
            }
            return (p.title, status, p.isOptional)
        }
        if a.json {
            Output.json(rows.map { ["permission": $0.0, "status": $0.1, "optional": $0.2] })
        } else {
            for r in rows { print("\(r.0)\t\(r.1)\(r.2 ? " (optional)" : "")") }
        }
        return 0
    }

    /// Currency for `hop convert`: "100 usd to eur", "€50 in gbp"; rates fetched when stale.
    static func convertCurrency(_ q: String, json: Bool) async -> Int32? {
        let rates = ExchangeRates.shared
        guard let query = CurrencyParser.parse(q, known: rates.codes) else { return nil }
        await rates.refreshNow()
        let home = AppSettings().data.calculator.currency
        let to = query.to ?? (query.from == home ? "USD" : home)
        guard let result = rates.convert(query.amount, from: query.from, to: to) else {
            return Output.fail("no exchange rate for \(query.from) or \(to)")
        }
        let formatted = String(format: "%.2f", (result as NSDecimalNumber).doubleValue)
        if json {
            Output.json(["amount": (query.amount as NSDecimalNumber).doubleValue, "from": query.from,
                         "result": (result as NSDecimalNumber).doubleValue, "to": to, "formatted": "\(formatted) \(to)"])
        } else {
            print("\(formatted) \(to)")
        }
        return 0
    }

    private static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isNewline).joined(separator: " ") }

    private static func stdinInput() -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
}

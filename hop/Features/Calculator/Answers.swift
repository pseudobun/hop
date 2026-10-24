import AppKit

/// One inline answer card in the root search: units, currency, time zones, dates,
/// colours or arithmetic, shown as "expression → result".
struct SmartAnswer {
    let kind: String // section title, e.g. "Currency"
    let expression: String
    let result: String
    let left: String
    let right: String
    /// What "Copy with Unit" copies, when it differs from `result`.
    var resultWithUnit: String?
    /// What the card shows, when it differs from `result` (which is what gets copied).
    var display: String?
    var swatch: NSColor?
    var extraActions: [Action] = []
}

enum Answers {
    /// The first answer the query is, in priority order (units, currency, time zones,
    /// dates, colours, arithmetic). `isAmbiguous`: the query also starts an app or
    /// command name, so loose answers (dates, arithmetic) stay out of the way.
    static func answer(for query: String, config: HopConfig, isAmbiguous: Bool, now: Date = Date()) -> SmartAnswer? {
        if let c = Converter.convert(query), !(c.implicitTarget && isAmbiguous) {
            let value = Converter.format(c.result)
            return SmartAnswer(kind: "Conversion", expression: "\(Converter.format(c.value)) \(c.from)", result: value,
                               left: c.fromName, right: c.toName, resultWithUnit: "\(value) \(c.to)", display: "\(value) \(c.to)")
        }
        if config.calculator.currencies, let a = currency(query, config: config) { return a }
        if let t = TimeZones.parse(query, now: now) {
            let shift = TimeZones.dayShift(t.from, from: t.fromZone, to: t.toZone)
            let day = shift == 0 ? "" : shift > 0 ? " · +\(shift) day" : " · \(shift) day"
            let result = TimeZones.clock(t.from, t.toZone)
            return SmartAnswer(kind: "Time Zones", expression: TimeZones.clock(t.from, t.fromZone), result: result,
                               left: "\(t.fromName) · \(TimeZones.offset(t.fromZone, at: t.from))",
                               right: "\(t.toName) · \(TimeZones.offset(t.toZone, at: t.from))\(day)")
        }
        if !isAmbiguous, let d = DateMath.parse(query, now: now) {
            switch d {
            case .date(let date, let withTime):
                return SmartAnswer(kind: "Date", expression: query.trimmingCharacters(in: .whitespaces), result: DateMath.format(date, withTime: withTime),
                                   left: "Expression", right: DateMath.relative(date, now: now))
            case .days(let n, let from, let to):
                let text = abs(n) == 1 ? "1 day" : "\(abs(n)) days"
                return SmartAnswer(kind: "Date", expression: "\(DateMath.short(from, now: now)) → \(DateMath.short(to, now: now))",
                                   result: "\(abs(n))", left: "Between", right: n < 0 ? "ago · \(DateMath.weeksAndDays(n))" : DateMath.weeksAndDays(n),
                                   resultWithUnit: text, display: text)
            case .week(let w, let y):
                return SmartAnswer(kind: "Date", expression: "Today", result: "\(w)", left: DateMath.format(now, withTime: false),
                                   right: "ISO week of \(y)", resultWithUnit: "Week \(w)", display: "Week \(w)")
            }
        }
        if let a = color(query) { return a }
        if !isAmbiguous, let value = Calculator.evaluateIfExpression(query) {
            return SmartAnswer(kind: "Calculator", expression: Calculator.pretty(query), result: Calculator.format(value),
                               left: "Expression", right: "Result")
        }
        return nil
    }

    private static func currency(_ query: String, config: HopConfig) -> SmartAnswer? {
        let rates = ExchangeRates.shared
        guard let q = CurrencyParser.parse(query, known: rates.codes) else { return nil }
        rates.refreshIfNeeded()
        let home = config.calculator.currency.uppercased()
        let to = q.to ?? (q.from == home ? (home == "USD" ? "EUR" : "USD") : home)
        guard let value = rates.convert(q.amount, from: q.from, to: to) else {
            return SmartAnswer(kind: "Currency", expression: "\(formatMoney(q.amount)) \(q.from)", result: "…",
                               left: q.from, right: rates.snapshot == nil ? "Fetching rates" : "No rate for \(to)")
        }
        let result = formatMoney(value)
        let date = rates.snapshot?.published.map { "Rates of " + DateMath.format($0, withTime: false) } ?? to
        return SmartAnswer(kind: "Currency", expression: "\(formatMoney(q.amount)) \(q.from)", result: result,
                           left: q.from, right: "\(to) · \(date)", resultWithUnit: "\(result) \(to)", display: "\(result) \(to)")
    }

    static func formatMoney(_ d: Decimal, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = abs((d as NSDecimalNumber).doubleValue) < 1 ? 4 : 2
        return f.string(from: d as NSDecimalNumber) ?? "\(d)"
    }

    /// "#7c5cff", "rgb(…)", "hsl(…)", optionally "… to rgb|hex|hsl".
    private static func color(_ query: String) -> SmartAnswer? {
        var q = query.trimmingCharacters(in: .whitespaces)
        var target: String?
        if let m = q.lowercased().firstMatch(of: /\s+(?:to|in|as|v)\s+(hex|rgb|hsl)$/) {
            target = String(m.1)
            q = String(q.prefix(q.count - m.0.count))
        }
        guard let c = ClipColor.parse(q) else { return nil }
        let isHex = q.hasPrefix("#")
        let out = target ?? (isHex ? "rgb" : "hex")
        let value = out == "hex" ? c.hex : out == "rgb" ? c.rgb : c.hsl
        let swatch = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        let copy = { (title: String, text: String) in
            Action(title: title, symbol: "paintpalette") {
                Pasteboard.copy(text)
                return .dismissWithHUD("Copied \(text)")
            }
        }
        let swiftUI = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f%@)", c.red, c.green, c.blue,
                             c.alpha < 1 ? String(format: ", opacity: %.2f", c.alpha) : "")
        return SmartAnswer(kind: "Color", expression: isHex ? c.hex : q, result: value,
                           left: isHex ? "HEX" : String(q.prefix(3)).uppercased(), right: out.uppercased(), swatch: swatch,
                           extraActions: [copy("Copy HEX", c.hex), copy("Copy RGB", c.rgb), copy("Copy HSL", c.hsl),
                                          copy("Copy SwiftUI Color", swiftUI)])
    }
}

/// Answers you copied or pasted, newest first (`calculator-history.json`).
final class CalculatorHistory {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var kind: String
        var expression: String
        var result: String
        var date: Date
    }

    static let shared = CalculatorHistory()
    private let store = JSONStore<[Entry]>(url: AppPaths.file("calculator-history.json"))
    private(set) var entries: [Entry]

    init() { entries = store.load() ?? [] }

    func record(_ a: SmartAnswer, now: Date = Date()) {
        entries.removeAll { $0.expression == a.expression && $0.result == a.result }
        entries.insert(Entry(kind: a.kind, expression: a.expression, result: a.result, date: now), at: 0)
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        entries = Array(entries.filter { $0.date > cutoff }.prefix(300))
        store.save(entries)
    }

    func delete(_ e: Entry) {
        entries.removeAll { $0 == e }
        store.save(entries)
    }

    func clear() {
        entries = []
        store.save(entries)
    }
}

/// "Calculator History": past answers; ↵ copies, ⌘↵ pastes, ⌘E puts the expression back.
final class CalculatorHistoryMode: Mode {
    let title: String? = "History"
    let tint: NSColor? = Theme.info
    let placeholder = "Search past calculations…"
    private weak var context: LauncherContext?

    func didEnter(_ context: LauncherContext) { self.context = context }

    func sections(for query: String) -> [ResultSection] {
        let history = CalculatorHistory.shared
        let words = query.split(whereSeparator: \.isWhitespace)
        let list = history.entries.filter { e in
            words.allSatisfy { w in [e.expression, e.result, e.kind].contains { $0.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        }
        if history.entries.isEmpty {
            return [ResultSection(title: nil, items: [Item(id: "calc.history.empty", title: "No calculations yet",
                                                           subtitle: "Answers you copy or paste from hop land here",
                                                           icon: .symbol("clock.arrow.circlepath", tint: Theme.info), actions: [], tracksFrecency: false)])]
        }
        return [ResultSection(title: "History", items: list.map { e in
            Item(id: "calc.\(e.date.timeIntervalSince1970)", title: e.result, subtitle: e.expression,
                 icon: .symbol(symbol(e.kind), tint: Theme.info), accessory: NoteStore.shortAge(e.date, now: Date()),
                 actions: [
                     Action(title: "Copy Answer", symbol: "doc.on.doc") {
                         Pasteboard.copy(e.result)
                         return .dismissWithHUD("Copied \(e.result)")
                     },
                     Action(title: "Paste Answer", symbol: "doc.on.clipboard", shortcut: .ret(.command)) { [weak self] in
                         self?.context?.dismiss()
                         if !(await Pasteboard.paste(e.result, concealed: false)) { HUD.shared.show("Copied. Allow hop in Accessibility to paste") }
                         return .stay
                     },
                     Action(title: "Calculate Again", symbol: "arrow.uturn.backward", shortcut: .cmd("e")) { [weak self] in
                         self?.context?.pop()
                         self?.context?.setQuery(e.expression)
                         return .stay
                     },
                     Action(title: "Delete", symbol: "trash", shortcut: KeyCombo(key: .character("x"), modifiers: .control), style: .destructive) {
                         CalculatorHistory.shared.delete(e)
                         return .reload
                     },
                     Action(title: "Clear History", symbol: "trash", shortcut: KeyCombo(key: .character("x"), modifiers: [.control, .shift]),
                            style: .destructive) {
                         .push(ConfirmMode(title: "Clear History", message: "Delete all \(CalculatorHistory.shared.entries.count) calculations?",
                                           confirmTitle: "Clear History", symbol: "trash.fill", tint: Theme.destructive) {
                             CalculatorHistory.shared.clear()
                             return .pop
                         })
                     },
                 ], tracksFrecency: false, monoTitle: true)
        })]
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "Currency": "dollarsign.circle"
        case "Time Zones": "globe"
        case "Date": "calendar"
        case "Color": "paintpalette"
        case "Conversion": "arrow.left.arrow.right"
        default: "equal.circle"
        }
    }
}

enum CalculatorCommands {
    static func items(_ services: Services) -> [Item] {
        [Item(id: "calculator.history", title: "Calculator History", subtitle: "Answers you copied or pasted",
              icon: .tile("clock.arrow.circlepath", Theme.info), accessory: "Command",
              actions: [Action(title: "Show History") { .push(CalculatorHistoryMode()) }], pushesMode: true)]
    }
}

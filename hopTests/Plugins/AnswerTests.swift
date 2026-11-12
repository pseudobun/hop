import Foundation
import Testing
@testable import hop

struct CurrencyTests {
    let known: Set<String> = ["USD", "EUR", "GBP", "RSD", "CHF", "JPY"]

    @Test func parsesAmountsAndCurrencies() {
        #expect(CurrencyParser.parse("100 usd to eur", known: known) == .init(amount: 100, from: "USD", to: "EUR"))
        #expect(CurrencyParser.parse("€50 in gbp", known: known) == .init(amount: 50, from: "EUR", to: "GBP"))
        #expect(CurrencyParser.parse("1.5k rsd v eur", known: known) == .init(amount: 1500, from: "RSD", to: "EUR"))
        #expect(CurrencyParser.parse("100 dollars to euros", known: known) == .init(amount: 100, from: "USD", to: "EUR"))
        #expect(CurrencyParser.parse("$1,250.50", known: known) == .init(amount: Decimal(string: "1250.5")!, from: "USD", to: nil))
        #expect(CurrencyParser.parse("1.250,50 €", known: known) == .init(amount: Decimal(string: "1250.5")!, from: "EUR", to: nil))
        #expect(CurrencyParser.parse("50 evrov v dolarje", known: known) == nil) // "dolarje" is not a known form
        #expect(CurrencyParser.parse("50 evrov v usd", known: known) == .init(amount: 50, from: "EUR", to: "USD"))
        #expect(CurrencyParser.parse("5 km to miles", known: known) == nil)
        #expect(CurrencyParser.parse("100 xyz to eur", known: known) == nil)
        #expect(CurrencyParser.parse("10 eur to eur", known: known) == nil)
    }

    @Test func convertsThroughTheBase() throws {
        let rates = ["EUR": 1.0, "USD": 1.10, "GBP": 0.85]
        let usd = try #require(ExchangeRates.convert(110, from: "USD", to: "GBP", rates: rates))
        #expect(abs((usd as NSDecimalNumber).doubleValue - 85) < 0.0001)
        #expect(ExchangeRates.convert(1, from: "USD", to: "XYZ", rates: rates) == nil)
        let json = #"{"result":"success","base_code":"EUR","time_last_update_unix":1792800000,"rates":{"EUR":1,"USD":1.1}}"#
        let snap = try #require(ExchangeRates.parse(Data(json.utf8)))
        #expect(snap.base == "EUR" && snap.rates["USD"] == 1.1 && snap.published != nil)
        #expect(ExchangeRates.parse(Data(#"{"result":"error"}"#.utf8)) == nil)
    }
}

struct TimeZoneTests {
    let ljubljana = TimeZone(identifier: "Europe/Ljubljana")!
    let winter: Date = { // 1 Dec 2026, 12:00 UTC: London GMT, Ljubljana CET
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 1; c.hour = 12; c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
    let gb = Locale(identifier: "en_GB")

    @Test func convertsTimesBetweenPlaces() throws {
        let a = try #require(TimeZones.parse("5pm london in ljubljana", now: winter, local: ljubljana))
        #expect(a.fromName == "London" && a.toName == "Ljubljana")
        #expect(TimeZones.clock(a.from, a.fromZone, locale: gb) == "17:00" && TimeZones.clock(a.from, a.toZone, locale: gb) == "18:00")
        let b = try #require(TimeZones.parse("14:00 CET to PST", now: winter, local: ljubljana))
        #expect(TimeZones.clock(b.from, b.toZone, locale: gb) == "05:00")
        let c = try #require(TimeZones.parse("3pm tokyo", now: winter, local: ljubljana))
        #expect(c.toName == "Here" && TimeZones.clock(c.from, c.toZone, locale: gb) == "07:00")
        let d = try #require(TimeZones.parse("time in new york", now: winter, local: ljubljana))
        #expect(d.toName == "New York" && TimeZones.clock(d.from, d.toZone, locale: gb) == "07:00")
        #expect(TimeZones.parse("tokio time", now: winter, local: ljubljana)?.toZone.identifier == "Asia/Tokyo")
        #expect(TimeZones.dayShift(TimeZones.parse("11pm ljubljana in tokyo", now: winter, local: ljubljana)!.from,
                                   from: ljubljana, to: TimeZone(identifier: "Asia/Tokyo")!) == 1)
    }

    @Test func rejectsNonTimes() {
        for q in ["5 in tokyo", "spotify", "time", "17:00", "5pm", "5pm nowhere in london"] {
            #expect(TimeZones.parse(q, now: winter, local: ljubljana) == nil, "\(q)")
        }
        #expect(TimeZones.clockTime("12am")! == (0, 0) && TimeZones.clockTime("12:30pm")! == (12, 30) && TimeZones.clockTime("17h")! == (17, 0))
        #expect(TimeZones.offset(ljubljana, at: winter) == "UTC+1")
        #expect(TimeZones.offset(TimeZone(identifier: "Asia/Kolkata")!, at: winter) == "UTC+5:30")
    }
}

struct DateMathTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Ljubljana")!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10))! } // a Saturday

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }

    private func date(_ q: String) -> Date? {
        if case .date(let d, _) = DateMath.parse(q, now: now, calendar: cal) { return cal.startOfDay(for: d) }
        return nil
    }

    @Test func namedAndRelativeDays() {
        #expect(date("tomorrow") == day(2026, 10, 25))
        #expect(date("jutri") == day(2026, 10, 25))
        #expect(date("in 3 weeks") == day(2026, 11, 14))
        #expect(date("čez 2 dni") == day(2026, 10, 26))
        #expect(date("3 days ago") == day(2026, 10, 21))
        #expect(date("next friday") == day(2026, 10, 30))
        #expect(date("last monday") == day(2026, 10, 19))
        #expect(date("christmas") == day(2026, 12, 25))
        #expect(date("24.12. + 30 days") == day(2027, 1, 23))
        #expect(date("2026-12-24 - 1 week") == day(2026, 12, 17))
        #expect(date("dec 24 2027") == day(2027, 12, 24))
        #expect(date("1.1.") == day(2027, 1, 1)) // the next one
    }

    @Test func durationsAndWeeks() {
        if case .days(let n, _, _) = DateMath.parse("days until christmas", now: now, calendar: cal) { #expect(n == 62) } else { Issue.record("no days") }
        if case .days(let n, _, _) = DateMath.parse("days since 1.1.2026", now: now, calendar: cal) { #expect(n == 296) } else { Issue.record("no days") }
        if case .days(let n, _, _) = DateMath.parse("2026-12-24 - today", now: now, calendar: cal) { #expect(n == 61) } else { Issue.record("no diff") }
        #expect(DateMath.parse("week number", now: now, calendar: cal) == .week(43, year: 2026))
        #expect(DateMath.weeksAndDays(61) == "8 weeks 5 days" && DateMath.weeksAndDays(1) == "1 day")
        #expect(DateMath.relative(day(2026, 10, 29), now: now, calendar: cal) == "in 5 days")
    }

    @Test func leavesOtherQueriesAlone() {
        for q in ["12", "2+2", "safari", "5 km", "monday.com", "1.5"] { #expect(DateMath.parse(q, now: now, calendar: cal) == nil, "\(q)") }
    }
}

struct AnswerTests {
    @Test func coloursGetASwatchAndFormats() throws {
        let a = try #require(Answers.answer(for: "#7c5cff", config: HopConfig(), isAmbiguous: false))
        #expect(a.kind == "Color" && a.result == "rgb(124, 92, 255)" && a.swatch != nil)
        #expect(a.extraActions.map(\.title).contains("Copy SwiftUI Color"))
        #expect(try #require(Answers.answer(for: "rgb(124, 92, 255) to hsl", config: HopConfig(), isAmbiguous: false)).result == "hsl(252, 100%, 68%)")
    }

    @Test func priorityAndAmbiguity() throws {
        #expect(Answers.answer(for: "5 km to mi", config: HopConfig(), isAmbiguous: false)?.kind == "Conversion")
        #expect(Answers.answer(for: "2+2", config: HopConfig(), isAmbiguous: false)?.result == "4")
        #expect(Answers.answer(for: "2+2", config: HopConfig(), isAmbiguous: true) == nil)
        #expect(Answers.answer(for: "tomorrow", config: HopConfig(), isAmbiguous: false)?.kind == "Date")
        #expect(Answers.answer(for: "time in tokyo", config: HopConfig(), isAmbiguous: true)?.kind == "Time Zones")
        #expect(Answers.formatMoney(1234.5, locale: Locale(identifier: "en_US")) == "1,234.50")
    }

    @Test func calculatorConfigDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let c = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(c.calculator == HopConfig.CalculatorSettings() && c.calculator.currency == "EUR")
    }
}

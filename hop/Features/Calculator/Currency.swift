import Foundation
import os

/// "100 usd to eur", "€50 in gbp", "1.5k rsd v eur", "100 dollars to euros".
nonisolated enum CurrencyParser {
    struct Query: Equatable {
        let amount: Decimal
        let from: String
        /// nil: convert to the home currency (or USD from it).
        let to: String?
    }

    static let symbols: [String: String] = [
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₽": "RUB", "₺": "TRY", "₴": "UAH",
        "₪": "ILS", "฿": "THB", "₫": "VND", "₱": "PHP", "zł": "PLN", "kč": "CZK", "ft": "HUF", "r$": "BRL", "a$": "AUD", "c$": "CAD",
        "us$": "USD", "chf": "CHF",
    ]

    static let names: [String: String] = [
        "dollar": "USD", "dollars": "USD", "dolar": "USD", "dolarjev": "USD", "dolarja": "USD", "dolarji": "USD", "buck": "USD", "bucks": "USD",
        "euro": "EUR", "euros": "EUR", "evro": "EUR", "evrov": "EUR", "evra": "EUR", "evri": "EUR", "eur": "EUR",
        "pound": "GBP", "pounds": "GBP", "quid": "GBP", "funt": "GBP", "funtov": "GBP", "funta": "GBP",
        "yen": "JPY", "jen": "JPY", "yuan": "CNY", "rmb": "CNY", "renminbi": "CNY", "franc": "CHF", "francs": "CHF", "frank": "CHF", "frankov": "CHF",
        "rupee": "INR", "rupees": "INR", "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "dinar": "RSD", "dinars": "RSD", "dinarjev": "RSD",
        "din": "RSD", "kuna": "HRK", "zloty": "PLN", "zlotys": "PLN", "forint": "HUF", "forints": "HUF", "koruna": "CZK", "lira": "TRY",
        "won": "KRW", "baht": "THB", "peso": "MXN", "pesos": "MXN", "real": "BRL", "reais": "BRL", "rand": "ZAR", "krona": "SEK",
        "kronor": "SEK", "krone": "NOK", "kroner": "NOK", "marka": "BAM",
    ]

    private static let separators: Set<String> = ["to", "in", "into", "as", "v", "na", "=", "->", "→"]

    /// `known`: currency codes there are rates for (ISO codes are only taken from it).
    static func parse(_ input: String, known: Set<String>) -> Query? {
        var q = input.trimmingCharacters(in: .whitespaces).lowercased()
        while q.hasSuffix("?") { q.removeLast() }
        guard q.count >= 2, q.count < 80 else { return nil }
        // Split "<amount from> <sep> <to>" on the last separator word or symbol.
        var left = q, right: String?
        let tokens = q.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let i = tokens.lastIndex(where: { separators.contains($0) }), i > 0, i < tokens.count - 1 {
            left = tokens[..<i].joined(separator: " ")
            right = tokens[(i + 1)...].joined(separator: " ")
        } else if let r = q.range(of: "→") ?? q.range(of: "->") ?? q.range(of: "=") {
            left = String(q[..<r.lowerBound])
            right = String(q[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if right?.isEmpty == true { right = nil }
        }
        guard let (amount, from) = amountAndCurrency(left.trimmingCharacters(in: .whitespaces), known: known) else { return nil }
        var to: String?
        if let right {
            guard let code = currency(right.trimmingCharacters(in: .whitespaces), known: known) else { return nil }
            to = code
        }
        guard to != from else { return nil }
        return Query(amount: amount, from: from, to: to)
    }

    static func currency(_ s: String, known: Set<String>) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let c = symbols[t] ?? names[t] { return c }
        let upper = t.uppercased()
        if upper.count == 3, upper.allSatisfy(\.isLetter), known.contains(upper) { return upper }
        return nil
    }

    /// "100 usd", "usd 100", "$100", "100$", "1.5k eur", "1,250.50 €".
    static func amountAndCurrency(_ s: String, known: Set<String>) -> (Decimal, String)? {
        let compact = s.replacingOccurrences(of: " ", with: "")
        // Leading or trailing currency marker.
        let markers = (Array(symbols.keys) + Array(names.keys) + known.map { $0.lowercased() }).sorted { $0.count > $1.count }
        for m in markers {
            if compact.hasPrefix(m), let n = number(String(compact.dropFirst(m.count))), let c = currency(m, known: known) { return (n, c) }
            if compact.hasSuffix(m), let n = number(String(compact.dropLast(m.count))), let c = currency(m, known: known) { return (n, c) }
        }
        return nil
    }

    /// "1,250.50", "1.250,50", "1.5k", "2m", "12".
    static func number(_ raw: String) -> Decimal? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var scale: Decimal = 1
        if let last = s.last?.lowercased(), ["k", "m"].contains(last) {
            scale = last == "k" ? 1000 : 1_000_000
            s.removeLast()
        }
        let commas = s.filter { $0 == "," }.count, dots = s.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            // The later one is the decimal separator.
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if commas == 1, let r = s.range(of: ","), s[r.upperBound...].count != 3 {
            s = s.replacingOccurrences(of: ",", with: ".") // 12,5
        } else {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        guard s.allSatisfy({ $0.isNumber || $0 == "." }), s.filter({ $0 == "." }).count <= 1, s.contains(where: \.isNumber),
              let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return d * scale
    }
}

/// Exchange rates (base EUR), cached on disk and refreshed twice a day from
/// open.er-api.com (free, no key, ~160 currencies).
final class ExchangeRates {
    static let shared = ExchangeRates()

    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        var base: String
        var rates: [String: Double]
        var fetched: Date
        var published: Date?
    }

    private(set) var snapshot: Snapshot?
    private var fetching = false
    private let store = JSONStore<Snapshot>(url: AppPaths.file("exchange-rates.json"))
    var onUpdate: (() -> Void)?
    var url = URL(string: "https://open.er-api.com/v6/latest/EUR")!

    init() { snapshot = store.load() }

    /// Codes there are rates for, plus the common ISO codes (so a first query can trigger the fetch).
    var codes: Set<String> { Self.isoCodes.union(snapshot.map { Array($0.rates.keys) } ?? []) }

    nonisolated static let isoCodes = Set(Locale.commonISOCurrencyCodes)

    /// `amount` of `from` in `to`, or nil without rates for both.
    func convert(_ amount: Decimal, from: String, to: String) -> Decimal? {
        snapshot.flatMap { Self.convert(amount, from: from, to: to, rates: $0.rates) }
    }

    nonisolated static func convert(_ amount: Decimal, from: String, to: String, rates: [String: Double]) -> Decimal? {
        guard let f = rates[from], let t = rates[to], f > 0 else { return nil }
        return amount * Decimal(t / f)
    }

    /// Fetches when there are no rates or they are older than 12 hours.
    func refreshIfNeeded() {
        if let s = snapshot, Date().timeIntervalSince(s.fetched) < 12 * 3600 { return }
        guard !fetching else { return }
        fetching = true
        let url = url
        Task {
            defer { fetching = false }
            guard let fresh = await Self.fetch(url) else { return }
            snapshot = fresh
            store.save(fresh)
            onUpdate?()
        }
    }

    @concurrent private static func fetch(_ url: URL) async -> Snapshot? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("hop", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// open.er-api.com: `{"result":"success","base_code":"EUR","time_last_update_unix":…,"rates":{…}}`.
    nonisolated static func parse(_ data: Data) -> Snapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["result"] as? String == "success", let base = json["base_code"] as? String,
              let rates = json["rates"] as? [String: Double], !rates.isEmpty else { return nil }
        let published = (json["time_last_update_unix"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Snapshot(base: base, rates: rates, fetched: Date(), published: published)
    }
}

import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Calculator plugin.
extension CalculatorPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["calc"], usage: [
                "calc <expression>                   Evaluate an expression",
            ], run: CLI.calc),
            CLICommand(names: ["convert"], usage: [
                "convert <query> [--json]            Convert units or currency: \"734h to min\", \"1 sq mile = km2\", \"100 usd to eur\"",
            ], run: CLI.convert),
        ]
    }
}

extension CLI {
    static func calc(_ a: Args) async -> Int32 {
        let expr = a.positional.joined(separator: " ")
        do {
            let v = try Calculator.evaluate(expr)
            let s = Calculator.format(v, locale: Locale(identifier: "en_US_POSIX"))
            if a.json { Output.json(["expression": expr, "result": s]) } else { print(s) }
            return 0
        } catch {
            return Output.fail("cannot evaluate: \(expr)")
        }
    }

    static func convert(_ a: Args) async -> Int32 {
        let q = a.positional.joined(separator: " ")
        guard let c = Converter.convert(q) else {
            return await convertCurrency(q, json: a.json) ?? Output.fail("cannot convert: \(q)")
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let result = Converter.format(c.result, locale: posix)
        if a.json {
            Output.json(["value": c.value, "from": c.from, "result": c.result, "to": c.to, "formatted": "\(result) \(c.to)"])
        } else {
            print("\(result) \(c.to)")
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
}

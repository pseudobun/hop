import Foundation

nonisolated extension HopConfig {
    nonisolated struct CalculatorSettings: PluginConfig {
        static let key = "calculator"
        /// Convert currencies; rates come from open.er-api.com, only once you type one.
        var currencies = true
        /// The currency an amount converts to when no target is typed.
        var currency = "EUR"
    }

    var calculator: CalculatorSettings {
        get { sections[CalculatorSettings.self] }
        set { sections[CalculatorSettings.self] = newValue }
    }
}

nonisolated extension HopConfig.CalculatorSettings {
    private enum Keys: String, CodingKey { case currencies, currency }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        currencies = try c.value(.currencies, d.currencies)
        currency = try c.value(.currency, d.currency)
    }
}

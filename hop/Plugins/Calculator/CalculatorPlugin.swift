import AppKit

/// Inline answers in root search: maths, units, currencies, time zones, dates and colours.
final class CalculatorPlugin: BuiltinPlugin {
    static var info: PluginInfo {
        PluginInfo(id: "calculator", name: "Calculator", summary: "Inline answers: maths, units, currencies.",
                   symbol: "plus.forwardslash.minus", color: Theme.chart2, category: .tools)
    }

    static var settings: [SettingsSection] {
        [
            SettingsSection([
                .setting("calculator.currencies", "Currencies", .toggle,
                  "Rates from open.er-api.com, fetched only after you type a currency, at most twice a day."),
                .setting("calculator.currency", "Default currency", .text(placeholder: "EUR"), "Where an amount goes when you type no target (\"50 usd\").", check: SettingsChecks.currency),
            ]),
        ]
    }

    init() {}

    private weak var host: PluginHost?

    func start(_ host: PluginHost) {
        self.host = host
        ExchangeRates.shared.onUpdate = { [weak host] in host?.reloadLauncher() }
    }

    func commands() -> [Item] { CalculatorCommands.items(host!.services) }

    func answer(for query: String, isAmbiguous: Bool) -> ResultSection? {
        guard let host, let a = Answers.answer(for: query, config: host.settings.data, isAmbiguous: isAmbiguous) else { return nil }
        return ResultSection(title: a.kind, items: [item(a)])
    }

    /// The answer card: ↵ copies the result, ⌘↵ pastes it, ⇧⌘C copies it with its unit.
    private func item(_ a: SmartAnswer) -> Item {
        let record = { CalculatorHistory.shared.record(a) }
        var actions = [
            Action(title: "Copy Answer") {
                record()
                Pasteboard.copy(a.result)
                return .dismissWithHUD("Copied \(a.result)")
            },
            Action(title: "Paste Answer", shortcut: .ret(.command)) { [weak host] in
                record()
                host?.launcher.dismiss()
                if !(await Pasteboard.paste(a.result, concealed: false)) {
                    HUD.shared.show("Copied. Allow hop in Accessibility to paste")
                }
                return .stay
            },
        ]
        if let unit = a.resultWithUnit, unit != a.result {
            actions.insert(Action(title: "Copy with Unit", shortcut: .cmd("c", .shift)) {
                record()
                Pasteboard.copy(unit)
                return .dismissWithHUD("Copied \(unit)")
            }, at: 1)
        }
        actions += a.extraActions
        var item = Item(id: "answer", title: a.display ?? a.result, subtitle: a.expression, actions: actions, tracksFrecency: false,
                        calculation: (a.expression, a.display ?? a.result, a.left, a.right))
        item.swatch = a.swatch
        return item
    }
}

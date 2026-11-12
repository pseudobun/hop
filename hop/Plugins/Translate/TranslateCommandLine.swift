import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Translate plugin.
extension TranslatePlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["tr", "translate"], usage: [
                "tr <text> [--to=CODE] [--json]      Translate between translate.languages with OpenAI (text or stdin)",
            ], run: CLI.translate),
        ]
    }
}

extension CLI {
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
}

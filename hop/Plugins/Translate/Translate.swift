import AppKit
import NaturalLanguage

/// Translation between the two languages in `translate.languages` with an OpenAI model:
/// text in the first language goes to the second, anything else to the first.
nonisolated enum Translator {
    /// A language by its ISO 639 code ("sl", "en", "de").
    struct Language: Hashable, Sendable {
        let code: String
        init(_ code: String) { self.code = code.lowercased() }
        /// English name ("Slovenian"), or the code when macOS does not know it.
        var name: String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }
    }

    /// The configured pair: `first` is the one detected text is translated out of.
    struct Pair: Equatable, Sendable {
        let first: Language
        let second: Language

        /// `translate.languages`; an empty or one-language list pairs the macOS language with
        /// English (or Spanish with English when macOS is in English).
        init(_ codes: [String]) {
            let system = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            let fallbackFirst = (system == nil || system == "en") ? "es" : system!
            let first = codes.first ?? fallbackFirst
            var second = codes.count > 1 ? codes[1] : "en"
            if second.lowercased() == first.lowercased() { second = first.lowercased() == "en" ? fallbackFirst : "en" }
            self.first = Language(first)
            self.second = Language(second)
        }

        func other(_ language: Language) -> Language { language == first ? second : first }

        /// Matches `--to` / a typed name against the pair: a code ("sl") or a name prefix ("slov").
        func language(named raw: String) -> Language? {
            let q = raw.lowercased()
            return [first, second].first { $0.code == q || $0.name.lowercased().hasPrefix(q) }
        }
    }

    /// Languages NaturalLanguage confuses for the given one in short text.
    private static let lookalikes: [String: [String]] = [
        "sl": ["hr", "sr", "bs"], "hr": ["sr", "bs", "sl"], "sr": ["hr", "bs"], "bs": ["hr", "sr"],
        "no": ["nb", "nn", "da"], "nb": ["no", "nn", "da"], "da": ["no", "nb"],
    ]

    /// Where `text` should go: the first language → the second, otherwise → the first.
    static func target(for text: String, pair: Pair) -> Language {
        let firstCodes = [pair.first.code] + (lookalikes[pair.first.code] ?? [])
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = (firstCodes + [pair.second.code]).map { NLLanguage($0) }
        recognizer.processString(text)
        guard let source = recognizer.dominantLanguage?.rawValue else { return pair.second }
        return firstCodes.contains(source) ? pair.second : pair.first
    }

    static func instructions(_ target: Language, pair: Pair) -> String {
        """
        You are a professional translator between \(pair.first.name) and \(pair.second.name). Translate \
        the user's text into \(target.name). Keep the meaning, tone, register (formal or casual) and \
        formatting: line breaks, lists, punctuation, code and names stay as they are. Use natural, \
        idiomatic phrasing a native speaker would write. Output only the translation.
        """
    }

    static func translate(_ text: String, to target: Language, pair: Pair, model: String, reasoning: String) async -> Result<String, OpenAI.Failure> {
        let maxTokens = max(400, text.utf8.count * 2)
        let reply = await OpenAI.chat(system: instructions(target, pair: pair), user: text, model: model, reasoning: reasoning,
                                      maxTokens: maxTokens, timeout: 30)
        return reply.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Root command.
enum TranslateCommands {
    static func items(_ services: Services) -> [Item] {
        guard services.settings.data.translate.enabled else { return [] }
        return [
            Item(id: "translate", title: "Translate", subtitle: "\(Translator.Pair(services.settings.data.translate.languages).first.name) ↔ \(Translator.Pair(services.settings.data.translate.languages).second.name), or type “tr ” first",
                 aliases: ["translation"], icon: .tile("character.bubble.fill", Palette.translate),
                 accessory: "Command",
                 actions: [Action(title: "Translate", symbol: "character.bubble") { .push(mode(services)) }],
                 pushesMode: true),
        ]
    }

    static func mode(_ services: Services) -> TranslateMode {
        let config = services.settings.data.translate
        return TranslateMode(pair: Translator.Pair(config.languages), model: config.model, reasoning: config.reasoning)
    }
}

/// Type or paste text; ↵ translates (first language → second, otherwise → first), ⌘↵ the
/// other way. With nothing typed, ↵ translates the clipboard. Only ↵ sends anything.
final class TranslateMode: Mode {
    let title: String? = "Translate"
    let tint: NSColor? = Palette.translate
    let placeholder = "Type or paste text · ↵ translates · ⌘↵ the other way"

    private let pair: Translator.Pair
    private let model: String
    private let reasoning: String
    private weak var context: LauncherContext?
    /// Translations this session, by target and text.
    private var done: [String: String] = [:]
    private var waiting: String?
    private var task: Task<Void, Never>?

    init(pair: Translator.Pair, model: String, reasoning: String) {
        self.pair = pair
        self.model = model
        self.reasoning = reasoning
    }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func didExit() {
        task?.cancel()
        waiting = nil
        context?.setLoading(false)
    }

    private static func key(_ text: String, _ target: Translator.Language) -> String { target.code + "\n" + text }

    func sections(for query: String) -> [ResultSection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [ResultSection(title: nil, items: clipboardItem().map { [$0] } ?? [])] }
        let target = Translator.target(for: text, pair: pair)
        var items: [Item] = []
        for t in [target, pair.other(target)] {
            if let result = done[Self.key(text, t)] { items.append(resultItem(result, target: t)) }
        }
        if waiting == Self.key(text, target) || waiting == Self.key(text, pair.other(target)) {
            let t = waiting == Self.key(text, target) ? target : pair.other(target)
            items.append(Item(id: "translate.waiting", title: "Translating to \(t.name)…", subtitle: model,
                              icon: .tile("ellipsis", Palette.translate), actions: [], tracksFrecency: false))
        }
        if done[Self.key(text, target)] == nil && waiting == nil {
            items.append(Item(id: "translate.go", title: "Translate to \(target.name)", subtitle: text,
                              icon: .tile("character.bubble.fill", Palette.translate), accessory: "↵",
                              actions: [translateAction(text, to: target),
                                        translateAction(text, to: pair.other(target), shortcut: .ret(.command))],
                              tracksFrecency: false))
        }
        return [ResultSection(title: nil, items: items)]
    }

    private func clipboardItem() -> Item? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let target = Translator.target(for: text, pair: pair)
        let preview = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return Item(id: "translate.clipboard", title: "Translate Clipboard to \(target.name)", subtitle: preview,
                    icon: .tile("doc.on.clipboard", Palette.translate),
                    actions: [Action(title: "Translate Clipboard", symbol: "character.bubble") { [weak self] in
                        self?.context?.setQuery(text)
                        self?.start(text, to: target)
                        return .stay
                    }], tracksFrecency: false)
    }

    private func translateAction(_ text: String, to target: Translator.Language, shortcut: KeyCombo? = nil) -> Action {
        Action(title: "Translate to \(target.name)", symbol: "character.bubble", shortcut: shortcut) { [weak self] in
            self?.start(text, to: target)
            return .stay
        }
    }

    private func resultItem(_ result: String, target: Translator.Language) -> Item {
        let oneLine = result.split(whereSeparator: \.isNewline).joined(separator: " ")
        return Item(id: "translate.result.\(target.name)", title: oneLine, subtitle: target.name,
                    icon: .tile("checkmark", Palette.translate),
                    actions: [
                        Action(title: "Paste Translation", symbol: "doc.on.clipboard") { [weak self] in
                            self?.context?.dismiss()
                            if !(await Pasteboard.paste(result, concealed: false)) {
                                HUD.shared.show("Copied. Allow hop in Accessibility to paste")
                            }
                            return .stay
                        },
                        Action(title: "Copy Translation", symbol: "doc.on.doc", shortcut: .cmd("c")) {
                            Pasteboard.copy(result)
                            return .dismissWithHUD("Copied translation")
                        },
                    ], tracksFrecency: false)
    }

    private func start(_ text: String, to target: Translator.Language) {
        let key = Self.key(text, target)
        guard done[key] == nil, waiting != key else { return }
        task?.cancel()
        waiting = key
        context?.setLoading(true)
        context?.reload()
        task = Task { [weak self, pair, model, reasoning] in
            let result = await Translator.translate(text, to: target, pair: pair, model: model, reasoning: reasoning)
            guard !Task.isCancelled, let self else { return }
            waiting = nil
            context?.setLoading(false)
            switch result {
            case .success(let translation): done[key] = translation
            case .failure(let error): HUD.shared.fail(OpenAI.describe(error))
            }
            context?.reload()
        }
    }
}

import AppKit
import NaturalLanguage

/// Slovenian ↔ English with an OpenAI model: Slovenian text goes to English, anything
/// else to Slovenian.
nonisolated enum Translator {
    enum Language: String, Sendable {
        case english = "English", slovenian = "Slovenian"
        var other: Language { self == .english ? .slovenian : .english }
    }

    /// Where `text` should go: Slovenian → English, otherwise → Slovenian.
    static func target(for text: String) -> Language {
        let recognizer = NLLanguageRecognizer()
        let slovenian = NLLanguage("sl"), serbian = NLLanguage("sr")
        recognizer.languageConstraints = [slovenian, .english, .croatian, serbian, .german]
        recognizer.processString(text)
        // Short Slovenian is often taken for Croatian or Serbian; neither is a source here.
        let source = recognizer.dominantLanguage
        return source == slovenian || source == .croatian || source == serbian ? .english : .slovenian
    }

    static func instructions(_ target: Language) -> String {
        """
        You are a professional translator between Slovenian and English. Translate the user's text \
        into \(target.rawValue). Keep the meaning, tone, register (formal or casual, ti or vi) and \
        formatting: line breaks, lists, punctuation, code and names stay as they are. Use natural, \
        idiomatic phrasing a native speaker would write. Output only the translation.
        """
    }

    static func translate(_ text: String, to target: Language, model: String, reasoning: String) async -> Result<String, OpenAI.Failure> {
        let maxTokens = max(400, text.utf8.count * 2)
        let reply = await OpenAI.chat(system: instructions(target), user: text, model: model, reasoning: reasoning,
                                      maxTokens: maxTokens, timeout: 30)
        return reply.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Root command.
enum TranslateCommands {
    static func items(_ services: Services) -> [Item] {
        guard services.settings.data.translate.enabled else { return [] }
        return [
            Item(id: "translate", title: "Translate", subtitle: "Slovenian ↔ English, or type “tr ” first",
                 aliases: ["prevedi", "prevod", "translation"], icon: .tile("character.bubble.fill", Palette.translate),
                 accessory: "Command",
                 actions: [Action(title: "Translate", symbol: "character.bubble") { .push(mode(services)) }],
                 pushesMode: true),
        ]
    }

    static func mode(_ services: Services) -> TranslateMode {
        let config = services.settings.data.translate
        return TranslateMode(model: config.model, reasoning: config.reasoning)
    }
}

/// Type or paste text; ↵ translates (Slovenian → English, otherwise → Slovenian), ⌘↵ the
/// other way. With nothing typed, ↵ translates the clipboard. Only ↵ sends anything.
final class TranslateMode: Mode {
    let title: String? = "Translate"
    let tint: NSColor? = Palette.translate
    let placeholder = "Type or paste text · ↵ translates · ⌘↵ the other way"

    private let model: String
    private let reasoning: String
    private weak var context: LauncherContext?
    /// Translations this session, by target and text.
    private var done: [String: String] = [:]
    private var waiting: String?
    private var task: Task<Void, Never>?

    init(model: String, reasoning: String) {
        self.model = model
        self.reasoning = reasoning
    }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func didExit() {
        task?.cancel()
        waiting = nil
        context?.setLoading(false)
    }

    private static func key(_ text: String, _ target: Translator.Language) -> String { target.rawValue + "\n" + text }

    func sections(for query: String) -> [ResultSection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [ResultSection(title: nil, items: clipboardItem().map { [$0] } ?? [])] }
        let target = Translator.target(for: text)
        var items: [Item] = []
        for t in [target, target.other] {
            if let result = done[Self.key(text, t)] { items.append(resultItem(result, target: t)) }
        }
        if waiting == Self.key(text, target) || waiting == Self.key(text, target.other) {
            let t = waiting == Self.key(text, target) ? target : target.other
            items.append(Item(id: "translate.waiting", title: "Translating to \(t.rawValue)…", subtitle: model,
                              icon: .tile("ellipsis", Palette.translate), actions: [], tracksFrecency: false))
        }
        if done[Self.key(text, target)] == nil && waiting == nil {
            items.append(Item(id: "translate.go", title: "Translate to \(target.rawValue)", subtitle: text,
                              icon: .tile("character.bubble.fill", Palette.translate), accessory: "↵",
                              actions: [translateAction(text, to: target),
                                        translateAction(text, to: target.other, shortcut: .ret(.command))],
                              tracksFrecency: false))
        }
        return [ResultSection(title: nil, items: items)]
    }

    private func clipboardItem() -> Item? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let target = Translator.target(for: text)
        let preview = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return Item(id: "translate.clipboard", title: "Translate Clipboard to \(target.rawValue)", subtitle: preview,
                    icon: .tile("doc.on.clipboard", Palette.translate),
                    actions: [Action(title: "Translate Clipboard", symbol: "character.bubble") { [weak self] in
                        self?.context?.setQuery(text)
                        self?.start(text, to: target)
                        return .stay
                    }], tracksFrecency: false)
    }

    private func translateAction(_ text: String, to target: Translator.Language, shortcut: KeyCombo? = nil) -> Action {
        Action(title: "Translate to \(target.rawValue)", symbol: "character.bubble", shortcut: shortcut) { [weak self] in
            self?.start(text, to: target)
            return .stay
        }
    }

    private func resultItem(_ result: String, target: Translator.Language) -> Item {
        let oneLine = result.split(whereSeparator: \.isNewline).joined(separator: " ")
        return Item(id: "translate.result.\(target.rawValue)", title: oneLine, subtitle: target.rawValue,
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
        task = Task { [weak self, model, reasoning] in
            let result = await Translator.translate(text, to: target, model: model, reasoning: reasoning)
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

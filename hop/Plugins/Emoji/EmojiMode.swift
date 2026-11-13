import AppKit
import os

/// Root command for the emoji picker.
enum EmojiCommands {
    static func items(_ services: Services) -> [Item] {
        guard services.settings.data.emoji.enabled else { return [] }
        return [
            Item(id: "emoji.search", title: "Search Emoji", subtitle: "Paste or copy an emoji, by name, slang or in Slovenian",
                 aliases: ["emoji", "emoticon", "smiley"], icon: .tile("face.smiling.inverse", Palette.emoji), accessory: "Command",
                 actions: [Action(title: "Search Emoji", symbol: "face.smiling") { .push(mode(services)) }],
                 pushesMode: true),
        ]
    }

    static func mode(_ services: Services) -> EmojiMode {
        let config = services.settings.data.emoji
        return EmojiMode(usage: .shared, skinTone: SkinTone(config: config.skinTone),
                         ai: config.ai ? (config.aiModel, config.aiReasoning) : nil)
    }
}

/// Which emoji were used and how often, as Raycast frecency anchors (`emoji-usage.json`
/// in Application Support); keyed by the emoji without a skin tone.
final class EmojiUsage {
    struct Entry: Codable {
        var anchor: Double
        var count: Int
        var lastUsed: Date
    }

    static let shared = EmojiUsage(store: JSONStore(url: AppPaths.file("emoji-usage.json")))

    private let store: JSONStore<[String: Entry]>
    private(set) var entries: [String: Entry]

    init(store: JSONStore<[String: Entry]>) {
        self.store = store
        entries = store.load() ?? [:]
    }

    func record(_ emoji: String, now: Date = Date()) {
        let old = entries[emoji]
        entries[emoji] = Entry(anchor: Frecency.visit(anchor: old?.anchor, at: now.timeIntervalSince1970),
                               count: (old?.count ?? 0) + 1, lastUsed: now)
        store.save(entries)
    }

    func score(_ emoji: String, now: Date = Date()) -> Double {
        entries[emoji].map { Frecency.score(anchor: $0.anchor, at: now.timeIntervalSince1970) } ?? 1
    }

    /// Most recent first.
    func recent(_ limit: Int) -> [String] {
        entries.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(limit).map(\.key)
    }

    /// Highest frecency first, among emoji used more than once.
    func frequent(_ limit: Int, now: Date = Date()) -> [String] {
        entries.filter { $0.value.count > 1 }.sorted { $0.value.anchor > $1.value.anchor }.prefix(limit).map(\.key)
    }
}

/// The picker: a grid of every emoji by category, recently and frequently used on top;
/// typing searches names, keywords (English, Slovenian) and slang.
final class EmojiMode: Mode {
    let title: String? = "Emoji"
    let tint: NSColor? = Palette.emoji
    let placeholder = "Search emoji… (wtf, ship it, srce) · ⌘↵ or ? asks AI"
    static let columns = 9
    var layout: ResultLayout { .grid(columns: Self.columns) }

    private let usage: EmojiUsage
    private let skinTone: SkinTone
    /// OpenAI model and reasoning effort for phrases the index can't place; nil is off.
    private let ai: (model: String, reasoning: String)?
    /// Model picks per query, as index entries; kept for the session, for `aiCacheModel`.
    private(set) static var aiCache: [String: [Int]] = [:]
    /// The model and reasoning effort `aiCache` and `warned` are for: another one starts over.
    private static var aiCacheModel: String?
    private var aiTask: Task<Void, Never>?
    /// The query `aiTask` is for, and whether its request is out (shown as a placeholder).
    private var aiQuery: String?
    private var aiWaiting = false
    /// Queries sent to the model by hand (⌘↵), though the index matched something.
    private var forcedAI: Set<String> = []
    /// One HUD per model for a failing API (bad key, retired model), not one per keystroke.
    private(set) static var warned = false
    private weak var context: LauncherContext?
    private var index: EmojiIndex?
    /// Shared across pushes: built once per launch, at first use.
    private static var cached: EmojiIndex?

    init(usage: EmojiUsage, skinTone: SkinTone, ai: (model: String, reasoning: String)? = nil, index: EmojiIndex? = nil) {
        self.usage = usage
        self.skinTone = skinTone
        self.ai = ai
        self.index = index ?? Self.cached
        if let ai { Self.useModel(ai.model, reasoning: ai.reasoning) }
    }

    /// Picks and the failure HUD belong to one model: `emoji.aiModel` or `aiReasoning` changed,
    /// so the next query asks the new one and a failure of it shows.
    static func useModel(_ model: String, reasoning: String) {
        let key = "\(model)|\(reasoning)"
        guard aiCacheModel != key else { return }
        aiCacheModel = key
        aiCache = [:]
        warned = false
    }

    #if DEBUG
    static func debugSeedAI(_ query: String, _ picks: [Int], warned: Bool) {
        aiCache[aiKey(query)] = picks
        self.warned = warned
    }
    #endif

    func didEnter(_ context: LauncherContext) {
        self.context = context
        guard index == nil else { return }
        context.setLoading(true)
        Task { [weak self] in
            let loaded = await EmojiIndex.load()
            context.setLoading(false)
            EmojiMode.cached = loaded
            guard let self else { return }
            index = loaded
            context.reload()
        }
    }

    func sections(for query: String) -> [ResultSection] {
        guard let index else { return [] }
        var q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || q == ":" { return browseSections(index) }
        // "?" in front asks the model straight away.
        let asked = q.hasPrefix("?")
        if asked { q = q.dropFirst().trimmingCharacters(in: .whitespaces) }
        guard !q.isEmpty else { return browseSections(index) }
        let now = Date()
        let order = index.search(q) { usage.score(index.entries[$0].emoji, now: now) }
        var matches = order.map { item(index, $0, id: "emoji.\($0)") }
        if ai != nil {
            let key = Self.aiKey(q)
            let askAction = Action(title: "Ask AI", symbol: "sparkles", shortcut: .ret(.command)) { [weak self] in
                self?.forcedAI.insert(key)
                return .reload
            }
            for i in matches.indices { matches[i].actions.append(askAction) }
        }
        let forced = asked || forcedAI.contains(Self.aiKey(q))
        guard ai != nil, Self.wantsAI(q, matches: order.count, forced: forced) else { return [ResultSection(title: nil, items: matches)] }
        guard let picks = Self.aiCache[Self.aiKey(q)] else {
            ask(q, index: index)
            guard aiWaiting, aiQuery == Self.aiKey(q) else { return [ResultSection(title: nil, items: matches)] }
            let waiting = Item(id: "emoji.ai.waiting", title: "Asking OpenAI…", subtitle: ai?.model, icon: .emoji("✨"),
                               actions: [], tracksFrecency: false)
            return [ResultSection(title: "Suggested", items: [waiting]), ResultSection(title: "Matches", items: matches)]
        }
        guard !picks.isEmpty else { return [ResultSection(title: nil, items: matches)] }
        let suggested = picks.map { item(index, $0, id: "emoji.ai.\($0)") }
        return [ResultSection(title: "Suggested", items: suggested), ResultSection(title: "Matches", items: matches)]
    }

    /// Only when the index found nothing, or when asked (⌘↵ or a leading "?"): no request per keystroke.
    nonisolated static func wantsAI(_ query: String, matches: Int, forced: Bool = false) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return forced ? q.count >= 2 : q.count >= 3 && matches == 0
    }

    nonisolated static func aiKey(_ query: String) -> String {
        query.lowercased().split(separator: " ").joined(separator: " ")
    }

    /// Asks the model once typing pauses; the rows update when the answer is in.
    private func ask(_ query: String, index: EmojiIndex) {
        guard let ai, aiQuery != Self.aiKey(query) else { return }
        aiTask?.cancel()
        aiQuery = Self.aiKey(query)
        aiWaiting = false
        context?.setLoading(false)
        aiTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, await OpenAIKey.load() != nil, let self else { return }
            aiWaiting = true
            context?.setLoading(true)
            context?.reload()
            let result = await EmojiAI.suggest(query, model: ai.model, reasoning: ai.reasoning)
            guard !Task.isCancelled else { return }
            aiWaiting = false
            aiQuery = nil
            context?.setLoading(false)
            switch result {
            case .success(let emoji):
                var seen = Set<Int>()
                Self.aiCache[Self.aiKey(query)] = emoji.compactMap(index.entry(for:)).filter { seen.insert($0).inserted }
                context?.reload()
            case .failure(let error):
                // Not asked again this session; the placeholder goes away.
                Self.aiCache[Self.aiKey(query)] = []
                context?.reload()
                Log.app.error("emoji ai: \(String(describing: error), privacy: .public)")
                guard !Self.warned, case .http(let status, _) = error, status != 0 else { return }
                Self.warned = true
                HUD.shared.warn(OpenAI.describe(error))
            }
        }
    }

    func didExit() {
        aiTask?.cancel()
        aiQuery = nil
        aiWaiting = false
        context?.setLoading(false)
    }

    private func browseSections(_ index: EmojiIndex) -> [ResultSection] {
        let lookup = { (emoji: String) in index.entry(for: emoji) }
        var sections = [
            ResultSection(title: "Recently Used", items: usage.recent(Self.columns).compactMap(lookup)
                .map { item(index, $0, id: "emoji.recent.\($0)") }),
            ResultSection(title: "Frequently Used", items: usage.frequent(Self.columns).compactMap(lookup)
                .map { item(index, $0, id: "emoji.frequent.\($0)") }),
        ]
        var byGroup = [[Item]](repeating: [], count: index.groups.count)
        for i in index.entries.indices { byGroup[index.entries[i].group].append(item(index, i, id: "emoji.\(i)")) }
        sections += zip(index.groups, byGroup).map { ResultSection(title: $0, items: $1) }
        return sections
    }

    /// One cell: ↵ pastes into the app behind hop, ⌘C copies, ⌘T picks a skin tone.
    func item(_ index: EmojiIndex, _ i: Int, id: String) -> Item {
        let entry = index.entries[i]
        let emoji = index.applying(skinTone, to: entry)
        let name = entry.name.prefix(1).uppercased() + entry.name.dropFirst()
        let usage = usage, base = entry.emoji, tone = skinTone
        var actions = Self.actions(emoji, name: name, record: { usage.record(base) }) { [weak self] in self?.context?.dismiss() }
        if entry.takesSkinTone {
            actions.append(Action(title: "Choose Skin Tone", symbol: "hand.raised", shortcut: .cmd("t")) {
                .push(EmojiToneMode(index: index, entry: i, usage: usage, selected: tone))
            })
        }
        return Item(id: id, title: name, subtitle: entry.keywords.prefix(5).joined(separator: " · "), icon: .emoji(emoji),
                    actions: actions, tracksFrecency: false)
    }

    /// Paste, copy, copy name, copy code; `dismiss` hides the launcher before pasting.
    static func actions(_ emoji: String, name: String, record: @escaping () -> Void,
                        dismiss: @escaping () -> Void) -> [Action] {
        [
            Action(title: "Paste Emoji", symbol: "doc.on.clipboard") {
                record()
                dismiss()
                if !(await Pasteboard.paste(emoji, concealed: false)) {
                    HUD.shared.show("Copied. Allow hop in Accessibility to paste")
                }
                return .stay
            },
            Action(title: "Copy Emoji", symbol: "doc.on.doc", shortcut: .cmd("c")) {
                record()
                Pasteboard.copy(emoji)
                return .dismissWithHUD("Copied \(emoji)")
            },
            Action(title: "Copy Name", symbol: "textformat", shortcut: .cmd("c", .shift)) {
                Pasteboard.copy(name)
                return .dismissWithHUD("Copied \(name)")
            },
            Action(title: "Copy Unicode Code", symbol: "number", shortcut: .cmd("c", .option)) {
                let code = codePoints(emoji)
                Pasteboard.copy(code)
                return .dismissWithHUD("Copied \(code)")
            },
        ]
    }

    /// "U+1F44D U+1F3FD", without variation selectors.
    static func codePoints(_ emoji: String) -> String {
        emoji.unicodeScalars.filter { $0.value != 0xFE0F }
            .map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }
}

/// One emoji in every skin tone (⌘T on a cell); typing filters by tone ("dark").
final class EmojiToneMode: Mode {
    let title: String? = "Skin Tone"
    let tint: NSColor? = Palette.emoji
    let placeholder = "Filter skin tones… (light, medium, dark)"
    var layout: ResultLayout { .grid(columns: SkinTone.allCases.count) }

    private let index: EmojiIndex
    private let entry: Int
    private let usage: EmojiUsage
    /// The configured tone, listed first so ↵ keeps today's behaviour.
    private let selected: SkinTone
    private weak var context: LauncherContext?

    init(index: EmojiIndex, entry: Int, usage: EmojiUsage, selected: SkinTone) {
        self.index = index
        self.entry = entry
        self.usage = usage
        self.selected = selected
    }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func sections(for query: String) -> [ResultSection] {
        let e = index.entries[entry]
        let base = e.name.prefix(1).uppercased() + e.name.dropFirst()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let tones = [selected] + SkinTone.allCases.filter { $0 != selected }
        let usage = usage
        let items = tones.compactMap { tone -> Item? in
            guard q.isEmpty || tone.label.lowercased().contains(q) else { return nil }
            let emoji = index.applying(tone, to: e)
            let name = tone == .none ? base : "\(base): \(tone.label.lowercased()) skin tone"
            return Item(id: "emoji.tone.\(tone.rawValue)", title: name, subtitle: tone.label, icon: .emoji(emoji),
                        actions: EmojiMode.actions(emoji, name: name, record: { usage.record(e.emoji) }) { [weak self] in
                            self?.context?.dismiss()
                        }, tracksFrecency: false)
        }
        return [ResultSection(title: nil, items: items)]
    }
}

extension SkinTone {
    var label: String {
        switch self {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-Light"
        case .medium: "Medium"
        case .mediumDark: "Medium-Dark"
        case .dark: "Dark"
        }
    }
}

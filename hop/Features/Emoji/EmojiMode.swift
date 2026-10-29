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
            Item(id: "emoji.openaiKey", title: "Set OpenAI API Key", subtitle: "Smarter emoji suggestions; kept in the Keychain",
                 aliases: ["openai"], icon: .tile("key.fill", Palette.emoji), accessory: "Command",
                 actions: [
                     Action(title: "Set Key", symbol: "key") { .push(OpenAIKeyMode()) },
                     Action(title: "Remove Key", symbol: "trash", shortcut: .ret(.command), style: .destructive) {
                         OpenAIKey.remove()
                         return .dismissWithHUD("OpenAI key removed")
                     },
                 ], tracksFrecency: false, pushesMode: true),
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
    let placeholder = "Search emoji… (wtf, ship it, srce)"
    static let columns = 9
    var layout: ResultLayout { .grid(columns: Self.columns) }

    private let usage: EmojiUsage
    private let skinTone: SkinTone
    /// OpenAI model and reasoning effort for phrases the index can't place; nil is off.
    private let ai: (model: String, reasoning: String)?
    /// Model picks per query, as index entries; kept for the session.
    private static var aiCache: [String: [Int]] = [:]
    private var aiTask: Task<Void, Never>?
    /// One HUD per launch for a failing API (bad key, retired model), not one per keystroke.
    private static var warned = false
    private weak var context: LauncherContext?
    private var index: EmojiIndex?
    /// Shared across pushes: built once per launch, at first use.
    private static var cached: EmojiIndex?

    init(usage: EmojiUsage, skinTone: SkinTone, ai: (model: String, reasoning: String)? = nil, index: EmojiIndex? = nil) {
        self.usage = usage
        self.skinTone = skinTone
        self.ai = ai
        self.index = index ?? Self.cached
    }

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
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || q == ":" { return browseSections(index) }
        let now = Date()
        let order = index.search(q) { usage.score(index.entries[$0].emoji, now: now) }
        let matches = order.map { item(index, $0, id: "emoji.\($0)") }
        guard ai != nil, Self.wantsAI(q, matches: order.count) else { return [ResultSection(title: nil, items: matches)] }
        guard let picks = Self.aiCache[Self.aiKey(q)] else {
            ask(q, index: index)
            return [ResultSection(title: nil, items: matches)]
        }
        let suggested = picks.map { item(index, $0, id: "emoji.ai.\($0)") }
        return [ResultSection(title: "Suggested", items: suggested), ResultSection(title: "Matches", items: matches)]
    }

    /// Phrases and queries the index barely matches; single words it knows stay local.
    nonisolated static func wantsAI(_ query: String, matches: Int) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.count >= 3 && (matches < 6 || q.split(separator: " ").count >= 2)
    }

    nonisolated static func aiKey(_ query: String) -> String {
        query.lowercased().split(separator: " ").joined(separator: " ")
    }

    /// Asks the model once typing pauses; the rows update when the answer is in.
    private func ask(_ query: String, index: EmojiIndex) {
        guard let ai else { return }
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let key = await OpenAIKey.load() else { return }
            let result = await EmojiAI.suggest(query, key: key, model: ai.model, reasoning: ai.reasoning)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let emoji):
                var seen = Set<Int>()
                Self.aiCache[Self.aiKey(query)] = emoji.compactMap(index.entry(for:)).filter { seen.insert($0).inserted }
                self?.context?.reload()
            case .failure(let error):
                Log.app.error("emoji ai: \(String(describing: error), privacy: .public)")
                guard !Self.warned, case .http(let status, let message) = error, status != 0 else { return }
                Self.warned = true
                HUD.shared.warn(status == 401 ? "OpenAI rejected the API key" : "OpenAI: \(message ?? "error \(status)")")
            }
        }
    }

    func didExit() { aiTask?.cancel() }

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

    /// One cell: ↵ pastes into the app behind hop, ⌘C copies.
    func item(_ index: EmojiIndex, _ i: Int, id: String) -> Item {
        let entry = index.entries[i]
        let emoji = index.applying(skinTone, to: entry)
        let name = entry.name.prefix(1).uppercased() + entry.name.dropFirst()
        let usage = usage, base = entry.emoji
        let record = { usage.record(base) }
        return Item(id: id, title: name, subtitle: entry.keywords.prefix(5).joined(separator: " · "), icon: .emoji(emoji),
                    actions: [
                        Action(title: "Paste Emoji", symbol: "doc.on.clipboard") { [weak self] in
                            record()
                            self?.context?.dismiss()
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
                            let code = Self.codePoints(emoji)
                            Pasteboard.copy(code)
                            return .dismissWithHUD("Copied \(code)")
                        },
                    ], tracksFrecency: false)
    }

    /// "U+1F44D U+1F3FD", without variation selectors.
    static func codePoints(_ emoji: String) -> String {
        emoji.unicodeScalars.filter { $0.value != 0xFE0F }
            .map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }
}

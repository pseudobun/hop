import AppKit

/// "Search Files": names first, then (optionally) files whose text matches. A query
/// starting with `/` or `~` browses that folder instead; Tab completes the path.
final class FileSearchMode: Mode {
    let title: String? = "Files"
    let tint: NSColor? = Palette.files
    private let settings: AppSettings
    private let frecency: FrecencyStore
    private weak var context: LauncherContext?

    private var nameHits: [FileHit] = []
    private var contentHits: [FileHit] = []
    private var searched = ""
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(settings: AppSettings, frecency: FrecencyStore) {
        self.settings = settings
        self.frecency = frecency
    }

    private var config: HopConfig.Files { settings.data.files }
    var placeholder: String { "Search files by name\(config.contentSearch ? " and text" : ""), or type ~/ to browse" }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func didExit() {
        searchTask?.cancel()
        context = nil
    }

    func sections(for query: String) -> [ResultSection] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let (dir, prefix) = FilePaths.split(q) {
            let hits = FilePaths.list(dir, prefix: prefix, showHidden: config.showHidden)
            let title = (dir as NSString).abbreviatingWithTildeInPath
            return [ResultSection(title: title, items: hits.prefix(200).map { item(for: $0, browsing: true) })]
        }
        guard q.count >= 2 else {
            return [ResultSection(title: nil, items: [Item(
                id: "files.hint", title: "Type at least two letters", subtitle: "Spotlight finds files in \(scopeNames)",
                icon: .symbol("magnifyingglass", tint: Palette.files), actions: [], tracksFrecency: false)])]
        }
        if q != searched { search(q) }
        var sections = [ResultSection(title: "Files", items: ranked(q).map { item(for: $0, browsing: false) })]
        let shown = Set(sections[0].items.map(\.id))
        let content = contentHits.filter { !shown.contains("file:" + $0.path) }
        if !content.isEmpty {
            sections.append(ResultSection(title: "In Contents", items: content.map { item(for: $0, browsing: false) }))
        }
        return sections
    }

    private var scopes: [String] { config.scopes.map(\.expandingTilde) }
    private var scopeNames: String { config.scopes.joined(separator: ", ") }

    /// Debounced, off the main thread; stale results are dropped.
    private func search(_ q: String) {
        searched = q
        generation += 1
        let gen = generation
        searchTask?.cancel()
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let scopes = scopes, exclude = config.exclude, content = config.contentSearch && q.count >= 3
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            self?.context?.setLoading(true)
            defer { if self?.generation == gen { self?.context?.setLoading(false) } }
            // 1. word starts (fast), 2. anywhere in the name when that found little, 3. text.
            var names = await Self.run(Spotlight.nameQuery(words), scopes: scopes, exclude: exclude, limit: 1500)
            guard let self, gen == generation, !Task.isCancelled else { return }
            nameHits = names
            contentHits = []
            context?.reload()
            if names.count < 40 && q.count >= 3 {
                let more = await Self.run(Spotlight.nameQuery(words, substring: true), scopes: scopes, exclude: exclude, limit: 1500)
                guard gen == generation, !Task.isCancelled else { return }
                let seen = Set(names.map(\.path))
                names += more.filter { !seen.contains($0.path) }
                nameHits = names
                context?.reload()
            }
            guard content else { return }
            let texts = await Self.run(Spotlight.contentQuery(words), scopes: scopes, exclude: exclude, limit: 300)
            guard gen == generation, !Task.isCancelled else { return }
            contentHits = Array(texts.prefix(30))
            context?.reload()
        }
    }

    @concurrent private static func run(_ query: String, scopes: [String], exclude: [String], limit: Int) async -> [FileHit] {
        Spotlight.run(query, scopes: scopes, limit: limit).filter { !FilePaths.isExcluded($0.path, patterns: exclude, scopes: scopes) }
    }

    /// Spotlight's matches ranked by the launcher's fuzzy scorer, frecency and recency.
    private func ranked(_ q: String) -> [FileHit] {
        let now = Date()
        let cands = nameHits.map { h in
            RankCandidate(id: "file:" + h.path, title: h.name, subtitle: h.parent, typeWeight: 1,
                          frecency: frecency.score("file:" + h.path, now: now) + FilePaths.recency(h, now: now))
        }
        let order = RootRanker.rank(cands, query: SearchQuery(q), sensitivity: .low)
        let rankedHits = order.map { nameHits[$0] }
        // Spotlight already matched every word; keep its leftovers after the fuzzy ones.
        let seen = Set(order)
        let rest = nameHits.indices.filter { !seen.contains($0) }.map { nameHits[$0] }
            .sorted { FilePaths.recency($0, now: now) > FilePaths.recency($1, now: now) }
        return Array((rankedHits + rest).prefix(config.maxResults))
    }

    private func item(for hit: FileHit, browsing: Bool) -> Item {
        let url = URL(fileURLWithPath: hit.path)
        let id = "file:" + hit.path
        let record: () -> Void = { [frecency] in frecency.recordVisit(id) }
        var actions: [Action] = []
        if browsing && hit.isDirectory {
            actions.append(Action(title: "Open Folder Here", symbol: "folder") { [weak self] in
                self?.context?.setQuery((hit.path as NSString).abbreviatingWithTildeInPath + "/")
                return .stay
            })
        }
        actions += [
            Action(title: "Open", symbol: "arrow.up.forward.app", shortcut: browsing && hit.isDirectory ? .ret(.shift) : nil) {
                record()
                NSWorkspace.shared.open(url)
                return .dismiss
            },
            Action(title: "Show in Finder", symbol: "folder", shortcut: .ret(.command)) {
                record()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .dismiss
            },
            Action(title: "Quick Look", symbol: "eye", shortcut: .cmd("y")) {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), arguments: ["-p", hit.path])
                return .stay
            },
            Action(title: "Copy Path", symbol: "link", shortcut: .cmd("c", .shift)) {
                Pasteboard.copy(hit.path)
                return .dismissWithHUD("Copied the path")
            },
            Action(title: "Copy File", symbol: "doc.on.doc", shortcut: .cmd("c", .option)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                return .dismissWithHUD("Copied \(hit.name)")
            },
            Action(title: "Open in Terminal", symbol: "terminal", shortcut: .cmd("t", .shift)) {
                let dir = hit.isDirectory ? url : url.deletingLastPathComponent()
                let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                if let terminal { NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) }
                return .dismiss
            },
            Action(title: "Move to Trash", symbol: "trash", shortcut: KeyCombo(key: .delete, modifiers: [.command]), style: .destructive) {
                .push(ConfirmMode(title: "Move to Trash", message: "Move \(hit.name) to the Trash?", confirmTitle: "Move to Trash",
                                  symbol: "trash.fill", tint: Theme.destructive) {
                    await Trash.move(url) ? .dismissWithHUD("Moved \(hit.name) to the Trash") : .failWithHUD("Could not move \(hit.name)")
                })
            },
        ]
        let age = (hit.lastUsed ?? hit.modified).map { NoteStore.shortAge($0, now: Date()) }
        return Item(id: id, title: hit.name, subtitle: browsing ? nil : hit.parent, icon: .file(hit.path), accessory: age,
                    actions: actions, tracksFrecency: false, pushesMode: browsing && hit.isDirectory)
    }

    /// Tab in a path query completes it.
    func complete(_ query: String) -> String? {
        guard let (dir, prefix) = FilePaths.split(query) else { return nil }
        return FilePaths.complete(query, hits: FilePaths.list(dir, prefix: prefix, showHidden: config.showHidden))
    }
}

/// Root command for file search.
enum FileCommands {
    static func items(_ services: Services) -> [Item] {
        guard services.settings.data.files.enabled else { return [] }
        let settings = services.settings, frecency = services.frecency
        return [Item(id: "files.search", title: "Search Files", subtitle: "Names and text, via Spotlight (or type “f ”, “~/”)",
                     icon: .tile("doc.text.magnifyingglass", Palette.files), accessory: "Command",
                     actions: [Action(title: "Search Files") { .push(FileSearchMode(settings: settings, frecency: frecency)) }],
                     pushesMode: true)]
    }
}

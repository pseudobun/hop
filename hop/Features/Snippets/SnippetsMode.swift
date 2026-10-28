import AppKit

/// Snippets for the launcher, the clipboard history and the expander: expands
/// placeholders against the clipboard history and pastes into the front app.
final class SnippetService {
    let file: SnippetsFile
    private let clipboard: ClipboardStore?
    /// Shows the launcher with an arguments prompt (snippets with `{argument}`).
    var presentArguments: ((Mode) -> Void)?

    init(file: SnippetsFile, clipboard: ClipboardStore?) {
        self.file = file
        self.clipboard = clipboard
    }

    var snippets: [Snippet] { file.snippets }

    func context(arguments: [String] = []) -> Placeholders.Context {
        var ctx = Placeholders.Context()
        ctx.snippets = snippets
        ctx.arguments = arguments
        ctx.calculate = { expr in
            (try? Calculator.evaluate(expr)).map { Calculator.format($0, locale: Locale(identifier: "en_US_POSIX")) }
        }
        let history = clipboard
        ctx.clipboard = { offset in
            if let items = history?.items, offset < items.count {
                let item = items[offset]
                return item.kind == .image || item.kind == .file ? item.title : item.text
            }
            return offset == 0 ? NSPasteboard.general.string(forType: .string) ?? "" : ""
        }
        return ctx
    }

    func expand(_ snippet: Snippet, arguments: [String] = []) throws -> Placeholders.Expansion {
        try Placeholders.expand(snippet.text, name: snippet.name, context: context(arguments: arguments))
    }

    /// Pastes a snippet into the front app, asking for its arguments first.
    /// `keyword`: typed text to delete first (expansion).
    func insert(_ snippet: Snippet, keyword: String? = nil) {
        let args = snippet.arguments
        if !args.isEmpty {
            Task {
                if let keyword { await SnippetExpander.replace(keyword: keyword, with: "", caretBack: nil) }
                presentArguments?(SnippetArgumentsMode(snippet: snippet, service: self))
            }
            return
        }
        do {
            let e = try expand(snippet)
            Task {
                if let keyword {
                    await SnippetExpander.replace(keyword: keyword, with: e.text, caretBack: e.charactersAfterCursor)
                } else {
                    await SnippetExpander.insert(e.text, caretBack: e.charactersAfterCursor)
                }
            }
        } catch Placeholders.ExpansionError.placeholder(let message) {
            HUD.shared.fail("\(snippet.name): \(message)")
        } catch {}
    }
}

/// "Search Snippets": ↵ pastes into the app you were in, ⌘↵ copies.
final class SnippetsMode: Mode {
    let title: String? = "Snippets"
    let tint: NSColor? = Palette.snippets
    let placeholder = "Search snippets…"
    private let service: SnippetService
    private let sensitivity: Sensitivity
    private weak var context: LauncherContext?

    init(service: SnippetService, sensitivity: Sensitivity) {
        self.service = service
        self.sensitivity = sensitivity
    }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func sections(for query: String) -> [ResultSection] {
        var list = Array(service.snippets.enumerated())
        if !query.isEmpty {
            let cands = list.map { RankCandidate(id: "\($0.offset)", title: $0.element.name, alternateTitles: [$0.element.keyword ?? ""],
                                                 keywords: [$0.element.text], typeWeight: 1) }
            list = RootRanker.rank(cands, query: SearchQuery(query), sensitivity: sensitivity).map { list[$0] }
        }
        var top: [Item] = []
        if let error = service.file.error {
            top.append(Item(id: "snippets.error", title: "snippets.json5 has an error", subtitle: error,
                            icon: .tile("exclamationmark.triangle.fill", Theme.warn), actions: [openFileAction], tracksFrecency: false))
        }
        if service.snippets.isEmpty {
            top.append(Item(id: "snippets.empty", title: "No snippets yet", subtitle: (service.file.url.path as NSString).abbreviatingWithTildeInPath,
                            icon: .tile("text.badge.plus", Palette.snippets), actions: [openFileAction], tracksFrecency: false))
        }
        let items = list.map { pair -> Item in
            let s = pair.element
            let preview = (try? service.expand(s, arguments: []).text) ?? s.text
            let firstLine = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? preview
            return Item(id: "snippet.\(pair.offset)", title: s.name, subtitle: firstLine,
                        icon: .tile("text.quote", Palette.snippets), accessory: s.keyword,
                        actions: [
                            Action(title: "Paste Snippet", symbol: "doc.on.clipboard") { [weak self] in
                                guard let self else { return .stay }
                                if !s.arguments.isEmpty { return .push(SnippetArgumentsMode(snippet: s, service: service)) }
                                context?.dismiss()
                                service.insert(s)
                                return .stay
                            },
                            Action(title: "Copy Snippet", symbol: "doc.on.doc", shortcut: .ret(.command)) { [weak self] in
                                guard let self else { return .stay }
                                do {
                                    Pasteboard.copy(try service.expand(s).text)
                                    return .dismissWithHUD("Copied \(s.name)")
                                } catch Placeholders.ExpansionError.placeholder(let m) {
                                    return .failWithHUD(m)
                                } catch { return .stay }
                            },
                            Action(title: "Copy Raw Text", symbol: "curlybraces", shortcut: .cmd("c", .shift)) {
                                Pasteboard.copy(s.text)
                                return .dismissWithHUD("Copied the template")
                            },
                            openFileAction,
                        ], tracksFrecency: false)
        }
        return [ResultSection(title: nil, items: top), ResultSection(title: "Snippets", items: items)]
    }

    private var openFileAction: Action {
        let url = service.file.url
        return Action(title: "Edit Snippets File", symbol: "pencil", shortcut: .cmd("e")) {
            NSWorkspace.shared.open(url)
            return .dismiss
        }
    }
}

/// Asks for a snippet's `{argument}` values one by one, then pastes it.
final class SnippetArgumentsMode: Mode {
    private let snippet: Snippet
    private let service: SnippetService
    private let arguments: [(name: String?, defaultValue: String?, options: [String]?)]
    private var values: [String] = []
    private weak var context: LauncherContext?

    init(snippet: Snippet, service: SnippetService) {
        self.snippet = snippet
        self.service = service
        arguments = snippet.arguments
    }

    var title: String? { snippet.name }
    var tint: NSColor? { Palette.snippets }

    private var current: (name: String?, defaultValue: String?, options: [String]?)? {
        values.count < arguments.count ? arguments[values.count] : nil
    }

    var placeholder: String {
        guard let a = current else { return "" }
        let name = a.name ?? "Argument \(values.count + 1)"
        let def = a.defaultValue.map { " (\($0))" } ?? ""
        return "\(name)\(def) · \(values.count + 1) of \(arguments.count), ↵ next"
    }

    func didEnter(_ context: LauncherContext) { self.context = context }

    func sections(for query: String) -> [ResultSection] {
        guard let a = current, let options = a.options, !options.isEmpty else { return [] }
        let shown = query.isEmpty ? options : options.filter { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return [ResultSection(title: a.name ?? "Options", items: shown.map { value in
            Item(id: "arg.\(value)", title: value, icon: .symbol("list.bullet", tint: Palette.snippets),
                 actions: [Action(title: "Choose") { [weak self] in self?.accept(value) ?? .stay }], tracksFrecency: false)
        })]
    }

    func submit(_ query: String) -> ActionResult? { accept(query) }

    private func accept(_ text: String) -> ActionResult {
        let value = text.isEmpty ? (current?.defaultValue ?? "") : text
        values.append(value)
        guard current == nil else {
            context?.setQuery("")
            context?.refreshChrome()
            return .stay
        }
        do {
            let e = try service.expand(snippet, arguments: values)
            context?.dismiss()
            Task { await SnippetExpander.insert(e.text, caretBack: e.charactersAfterCursor) }
            return .stay
        } catch Placeholders.ExpansionError.placeholder(let m) {
            return .failWithHUD(m)
        } catch {
            return .stay
        }
    }
}

/// Root commands for snippets.
enum SnippetCommands {
    static func items(_ services: Services) -> [Item] {
        let config = services.settings.data.snippets
        guard config.enabled, let service = services.snippets else { return [] }
        let sensitivity = services.settings.data.general.sensitivity
        let count = service.snippets.count
        return [
            Item(id: "snippets.search", title: "Search Snippets",
                 subtitle: "\(count) snippet\(count == 1 ? "" : "s")\(config.expand ? ", keywords expand as you type" : "")",
                 icon: .tile("text.quote", Palette.snippets), accessory: "Command",
                 actions: [Action(title: "Search Snippets") { .push(SnippetsMode(service: service, sensitivity: sensitivity)) }],
                 pushesMode: true),
            Item(id: "snippets.edit", title: "Edit Snippets", subtitle: (service.file.url.path as NSString).abbreviatingWithTildeInPath,
                 icon: .tile("pencil", Palette.snippets), accessory: "Command",
                 actions: [Action(title: "Open Snippets File") {
                     NSWorkspace.shared.open(service.file.url)
                     return .dismiss
                 }]),
        ]
    }
}

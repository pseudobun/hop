import AppKit

/// Raycast-style fallback commands: the root query handed to ChatGPT, Google or GitHub.
/// Listed under the results, and alone when nothing matches so ↵ runs the first one.
enum FallbackSearch {
    struct Engine: Equatable {
        let id: String
        let title: String
        let symbol: String
        /// The URL with `{query}` where the percent-encoded query goes.
        let template: String
    }

    static let builtIn: [Engine] = [
        // chatgpt.com/?q= fills in the prompt and sends it.
        Engine(id: "chatgpt", title: "Ask ChatGPT", symbol: "bubble.left.and.text.bubble.right.fill",
               template: "https://chatgpt.com/?q={query}"),
        Engine(id: "google", title: "Search Google", symbol: "magnifyingglass",
               template: "https://www.google.com/search?q={query}"),
        Engine(id: "github", title: "Search GitHub", symbol: "chevron.left.forwardslash.chevron.right",
               template: "https://github.com/search?q={query}"),
    ]

    /// A built-in id ("chatgpt") or a URL template with `{query}`; nil for anything else.
    static func engine(_ entry: String) -> Engine? {
        let key = entry.trimmingCharacters(in: .whitespaces)
        if let e = builtIn.first(where: { $0.id == key.lowercased() }) { return e }
        guard key.contains("{query}"),
              let host = URL(string: key.replacingOccurrences(of: "{query}", with: "q"))?.host(), !host.isEmpty
        else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return Engine(id: key, title: "Search \(name)", symbol: "globe", template: key)
    }

    /// RFC 3986 unreserved characters only: `&`, `+`, `#`, `=` and spaces are all escaped.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(_ engine: Engine, query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: engine.template.replacingOccurrences(of: "{query}", with: encoded))
    }

    /// Not for an empty query or a path (`~/…`, `/…`, which belong to file search).
    static func applies(to query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !q.isEmpty && !q.hasPrefix("/") && !q.hasPrefix("~/") && q != "~"
    }

    static func section(for query: String, entries: [String]) -> ResultSection? {
        guard applies(to: query) else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        let items: [Item] = entries.compactMap(engine).compactMap { e in
            guard seen.insert(e.id).inserted, let url = url(e, query: q) else { return nil }
            return item(e, url: url, query: q)
        }
        guard !items.isEmpty else { return nil }
        return ResultSection(title: "Use “\(q)” with…", items: items)
    }

    private static func item(_ e: Engine, url: URL, query: String) -> Item {
        let tint = switch e.id {
        case "chatgpt": Theme.chart1
        case "google": Theme.info
        case "github": Theme.chart5
        default: Theme.mutedForeground
        }
        return Item(id: "fallback.\(e.id)", title: e.title, subtitle: query, icon: .tile(e.symbol, tint),
                    accessory: url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 },
                    actions: [
                        Action(title: e.title, symbol: e.symbol) {
                            NSWorkspace.shared.open(url)
                            return .dismiss
                        },
                        Action(title: "Copy URL", shortcut: .cmd("c", .shift)) {
                            Pasteboard.copy(url.absoluteString)
                            return .dismissWithHUD("Copied URL")
                        },
                    ], tracksFrecency: false)
    }
}

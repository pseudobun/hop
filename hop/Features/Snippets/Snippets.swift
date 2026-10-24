import Foundation
import os

/// One snippet from `snippets.json5`: a name, an optional keyword that expands as you
/// type, and the text (with `{placeholders}`).
nonisolated struct Snippet: Decodable, Equatable, Sendable {
    var name: String
    var keyword: String?
    var text: String

    private enum Keys: String, CodingKey { case name, keyword, text }

    init(name: String, keyword: String? = nil, text: String) {
        self.name = name
        self.keyword = keyword
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? String(text.prefix(40))
        let k = try c.decodeIfPresent(String.self, forKey: .keyword)?.trimmingCharacters(in: .whitespaces)
        keyword = (k?.isEmpty ?? true) ? nil : k
    }

    /// Arguments the user fills in before the snippet is inserted, in position order.
    var arguments: [(name: String?, defaultValue: String?, options: [String]?)] {
        var seen: [Int: (String?, String?, [String]?)] = [:]
        for p in Placeholders.parse(text) {
            if case .argument(let pos, let name, let def, let opts) = p.value, seen[pos] == nil { seen[pos] = (name, def, opts) }
        }
        return seen.keys.sorted().map { seen[$0]! }
    }
}

/// `~/.config/hop/snippets.json5` (JSON5 array), reloaded when it changes; hop only
/// ever appends to it.
@MainActor
final class SnippetsFile {
    private(set) var snippets: [Snippet] = []
    private(set) var error: String?
    var onChange: (() -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?

    var url: URL

    init(url: URL) { self.url = url }

    static let template = """
    // hop snippets (JSON5). Type a keyword anywhere to expand it, or search them in hop.
    // Placeholders: {clipboard} {clipboard offset=1} {date} {date format="yyyy-MM-dd"} {time} {datetime} {day}
    //   {date offset="+1d -2h"} {uuid} {cursor} {argument name="who" default="you"} {snippet name="Signature"}
    //   {calculator expression="2*21"}; modifiers: {clipboard | trim | uppercase}, lowercase, percent-encode, json-stringify
    [
      { name: "Email", keyword: ";mail", text: "you@example.com" },
      { name: "Today", keyword: ";date", text: "{date format=\\"yyyy-MM-dd\\"}" },
      { name: "Signature", text: "Lp,\\nUrban" },
    ]

    """

    func start() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.template.write(to: url, atomically: true, encoding: .utf8)
        }
        load()
        watch()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            snippets = []
            onChange?()
            return
        }
        do {
            snippets = try Self.decode(data)
            error = nil
        } catch {
            self.error = "snippets.json5: \(error.localizedDescription)"
            Log.app.error("\(self.error ?? "", privacy: .public)")
        }
        onChange?()
    }

    nonisolated static func decode(_ data: Data) throws -> [Snippet] {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode([Snippet].self, from: data).filter { !$0.text.isEmpty }
    }

    private func watch() {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadTask?.cancel()
                self?.reloadTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.load()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Adds a snippet before the closing `]`, keeping the file's comments and layout.
    @discardableResult
    func append(_ snippet: Snippet) -> Bool {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "[\n]\n"
        guard let updated = Self.appending(snippet, to: text) else { return false }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            load()
            return true
        } catch {
            return false
        }
    }

    nonisolated static func appending(_ snippet: Snippet, to file: String) -> String? {
        guard let close = file.lastIndex(of: "]") else { return nil }
        func json(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        var entry = "  { name: \(json(snippet.name)), "
        if let k = snippet.keyword { entry += "keyword: \(json(k)), " }
        entry += "text: \(json(snippet.text)) },\n"
        var head = String(file[..<close])
        // A missing comma after the previous entry would break the array.
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last != "[" && last != "," {
            if let r = head.range(of: String(last), options: .backwards) { head.insert(",", at: r.upperBound) }
        }
        if !head.hasSuffix("\n") { head += "\n" }
        return head + entry + file[close...]
    }
}

/// Finds a snippet keyword at the end of what was just typed.
nonisolated enum SnippetMatcher {
    /// The snippet whose keyword `typed` ends with (the longest wins). Unless
    /// `withinWords`, a keyword that starts with a letter or digit needs a non-word
    /// character (or nothing) before it, so `;mail` expands anywhere but `addr` only as a word.
    static func match(_ typed: String, keywords: [(keyword: String, index: Int)], withinWords: Bool) -> (index: Int, keyword: String)? {
        for k in keywords.sorted(by: { $0.keyword.count > $1.keyword.count }) where !k.keyword.isEmpty && typed.hasSuffix(k.keyword) {
            if withinWords { return (k.index, k.keyword) }
            let before = typed.dropLast(k.keyword.count).last
            let startsWord = k.keyword.first.map { $0.isLetter || $0.isNumber } ?? false
            if !startsWord || before == nil || !(before!.isLetter || before!.isNumber) { return (k.index, k.keyword) }
        }
        return nil
    }
}

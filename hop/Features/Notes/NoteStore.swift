import Foundation

/// One Markdown file in the notes folder.
nonisolated struct NoteFile: Sendable, Hashable {
    let url: URL
    /// Path inside the notes folder, e.g. "Infra/Machines/olympus.md".
    let relativePath: String
    let modified: Date
    /// Evicted by iCloud: only a `.name.md.icloud` placeholder is on disk.
    var isPlaceholder = false

    /// File name without `.md`; Obsidian's page title.
    var title: String { (url.lastPathComponent as NSString).deletingPathExtension }
    /// Folder inside the notes folder, "" for the root.
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

/// A search result: the note, plus the matching line when only its text matched.
nonisolated struct NoteHit: Sendable, Equatable {
    let note: NoteFile
    var snippet: String?
    var pinned = false
    /// Occurrences of the search terms in the note's text.
    var matches = 0
    /// UTF-16 offset of the first match in the text (body before frontmatter).
    var matchLocation: Int?
    /// Words and phrases to highlight and jump to.
    var terms: [String] = []
}

/// A notes search: words and "phrases" that must all appear, `-excluded` words,
/// `path:` folder filters and `#tag` / `tag:` filters (frontmatter `tags:` or inline).
nonisolated struct NoteQuery: Equatable, Sendable {
    var terms: [String] = []
    var excluded: [String] = []
    var paths: [String] = []
    var tags: [String] = []

    var isEmpty: Bool { terms.isEmpty && excluded.isEmpty && paths.isEmpty && tags.isEmpty }
    /// What the title ranking sees: the plain terms.
    var titleText: String { terms.joined(separator: " ") }

    static func parse(_ text: String) -> NoteQuery {
        var tokens: [(text: String, phrase: Bool)] = []
        var current = "", inQuotes = false
        func flush(_ phrase: Bool) {
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { tokens.append((current, phrase)) }
            current = ""
        }
        for ch in text {
            if ch == "\"" {
                flush(inQuotes)
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush(false)
            } else {
                current.append(ch)
            }
        }
        flush(inQuotes) // an unclosed quote is still a phrase

        var q = NoteQuery()
        for (token, phrase) in tokens {
            let lower = token.lowercased()
            if phrase {
                q.terms.append(token)
            } else if token.count > 1 && token.hasPrefix("-") {
                q.excluded.append(String(token.dropFirst()))
            } else if let prefix = ["path:", "in:"].first(where: { lower.hasPrefix($0) }), token.count > prefix.count {
                q.paths.append(String(token.dropFirst(prefix.count)))
            } else if lower.hasPrefix("tag:"), token.count > 4 {
                q.tags.append(String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#")))
            } else if token.count > 1 && token.hasPrefix("#") && !token.dropFirst().hasPrefix("#") {
                q.tags.append(String(token.dropFirst()))
            } else {
                q.terms.append(token)
            }
        }
        return q
    }
}

/// Pinned notes per vault, as relative paths in the order they were pinned.
final class NotesPins {
    private let store = JSONStore<[String: [String]]>(url: AppPaths.file("notes-pins.json"))
    private var data: [String: [String]]

    init() { data = store.load() ?? [:] }

    func paths(in root: URL) -> [String] { data[Self.key(root)] ?? [] }

    func contains(_ path: String, in root: URL) -> Bool { paths(in: root).contains(path) }

    func toggle(_ path: String, in root: URL) {
        var list = paths(in: root)
        if let i = list.firstIndex(of: path) { list.remove(at: i) } else { list.append(path) }
        set(list, in: root)
    }

    func remove(_ path: String, in root: URL) {
        let list = paths(in: root)
        if list.contains(path) { set(list.filter { $0 != path }, in: root) }
    }

    private func set(_ list: [String], in root: URL) {
        data[Self.key(root)] = list.isEmpty ? nil : list
        store.save(data)
    }

    private static func key(_ root: URL) -> String { root.standardizedFileURL.path }
}

/// Files, names, frontmatter and search for a folder of Markdown notes (an Obsidian vault).
nonisolated enum NoteStore {
    // MARK: Scan

    /// Every `.md` file under `root`, newest first. Skips hidden folders (`.obsidian`,
    /// `.trash`, `.git`) and lists iCloud placeholders under their real name.
    static func scan(_ root: URL) throws -> [NoteFile] {
        let fm = FileManager.default
        _ = try fm.contentsOfDirectory(atPath: root.path) // surfaces "not found" / "not permitted"
        guard let walker = fm.enumerator(atPath: root.path) else { return [] }
        var notes: [NoteFile] = []
        while let path = walker.nextObject() as? String {
            let attributes = walker.fileAttributes
            let name = (path as NSString).lastPathComponent
            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                if name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            var relative = path
            var placeholder = false
            if name.hasPrefix(".") {
                guard name.hasSuffix(".md.icloud") else { continue }
                let dir = (path as NSString).deletingLastPathComponent
                relative = (dir as NSString).appendingPathComponent(String(name.dropFirst().dropLast(7)))
                placeholder = true
            } else if (name as NSString).pathExtension.lowercased() != "md" {
                continue
            }
            notes.append(NoteFile(url: root.appending(path: relative), relativePath: relative,
                                  modified: attributes?[.modificationDate] as? Date ?? .distantPast, isPlaceholder: placeholder))
        }
        return notes.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.relativePath < $1.relativePath }
    }

    // MARK: Search

    /// Title matches first (ranked like the launcher), then notes whose text contains
    /// every word of the query, with the first matching line as a snippet.
    /// Marks pinned hits; without a query they come first, in the order they were pinned.
    static func pinnedFirst(_ hits: [NoteHit], pinned: [String], query: String) -> [NoteHit] {
        guard !pinned.isEmpty else { return hits }
        var order: [String: Int] = [:]
        for (i, path) in pinned.enumerated() where order[path] == nil { order[path] = i }
        let marked = hits.map { h in
            var h = h
            h.pinned = order[h.note.relativePath] != nil
            return h
        }
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return marked }
        return marked.filter(\.pinned).sorted { order[$0.note.relativePath]! < order[$1.note.relativePath]! }
            + marked.filter { !$0.pinned }
    }

    static func search(_ notes: [NoteFile], query: String, contents: [String: String],
                       sensitivity: Sensitivity = .high) -> [NoteHit] {
        let q = NoteQuery.parse(query)
        guard !q.isEmpty else { return notes.map { NoteHit(note: $0) } }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func has(_ s: String, _ term: String) -> Bool { s.range(of: term, options: options) != nil }

        // Filters every hit must pass.
        let passing: [Int] = notes.indices.filter { i in
            let note = notes[i], text = contents[note.relativePath] ?? ""
            if !q.paths.allSatisfy({ has(note.relativePath, $0) }) { return false }
            if q.excluded.contains(where: { has(note.title, $0) || has(text, $0) }) { return false }
            if !q.tags.isEmpty {
                let tags = Self.tags(text)
                let wanted = q.tags.map { $0.lowercased() }
                if !wanted.allSatisfy({ t in tags.contains { $0 == t || $0.hasPrefix(t + "/") } }) { return false }
            }
            return true
        }
        guard !q.terms.isEmpty else { return passing.map { NoteHit(note: notes[$0]) } }

        // Titles first, ranked like the launcher.
        let cands = passing.map { RankCandidate(id: notes[$0].relativePath, title: notes[$0].title, subtitle: notes[$0].folder, typeWeight: 1) }
        let titled = RootRanker.rank(cands, query: SearchQuery(q.titleText), sensitivity: sensitivity).map { passing[$0] }
        var hits = titled.map { i -> NoteHit in
            var h = NoteHit(note: notes[i], terms: q.terms)
            if let text = contents[notes[i].relativePath] { (h.matches, h.matchLocation) = Self.matchInfo(text, terms: q.terms) }
            return h
        }

        // Then every note whose title or text holds all terms, most relevant first.
        let seen = Set(titled)
        let phrase = q.terms.count > 1 ? q.titleText : nil
        var scored: [(hit: NoteHit, score: Int)] = []
        for i in passing where !seen.contains(i) {
            let note = notes[i]
            guard let text = contents[note.relativePath],
                  q.terms.allSatisfy({ has(note.title, $0) || has(text, $0) }) else { continue }
            let (count, location) = Self.matchInfo(text, terms: q.terms)
            var hit = NoteHit(note: note, matches: count, matchLocation: location, terms: q.terms)
            hit.snippet = location.map { Self.snippet(text, at: $0) }
            let bodyStart = Self.frontmatterRange(text).map { NSRange($0, in: text).upperBound } ?? 0
            var score = min(count, 20)
            if let phrase, has(text, phrase) { score += 15 }
            if let location, location >= bodyStart { score += 5 }
            if q.terms.contains(where: { has(note.title, $0) }) { score += 10 }
            scored.append((hit, score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.hit.note.modified > $1.hit.note.modified }
        return hits + scored.map(\.hit)
    }

    /// How often the terms occur, and where the first one is (preferring the body to frontmatter).
    static func matchInfo(_ text: String, terms: [String]) -> (count: Int, location: Int?) {
        let ns = text as NSString
        let bodyStart = frontmatterRange(text).map { NSRange($0, in: text).upperBound } ?? 0
        var count = 0
        var firstBody: Int?, firstAny: Int?
        for term in terms where !term.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                count += 1
                if r.location >= bodyStart { firstBody = min(firstBody ?? r.location, r.location) }
                firstAny = min(firstAny ?? r.location, r.location)
                from = r.upperBound
            }
        }
        return (count, firstBody ?? firstAny)
    }

    /// The trimmed line around a UTF-16 offset, shortened to `width` with the match near
    /// the start (the sidebar shows about 45 characters).
    static func snippet(_ text: String, at location: Int, width: Int = 60) -> String {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let raw = ns.substring(with: lineRange)
        let leading = (raw.prefix { $0.isWhitespace } as Substring).utf16.count
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard line.length > width else { return line as String }
        let offset = max(0, location - lineRange.location - leading)
        let start = max(0, min(offset - 16, line.length - width))
        let piece = line.substring(with: NSRange(location: start, length: width)).trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + piece + (start + width < line.length ? "…" : "")
    }

    private nonisolated(unsafe) static let inlineTag = try! NSRegularExpression(pattern: #"(?<![\w#/&])#([\p{L}_][\p{L}\p{N}_/-]*)"#)

    /// Tags of a note, lower-cased without `#`: frontmatter `tags:` (inline list or
    /// YAML list) plus inline `#tags` in the body.
    static func tags(_ text: String) -> Set<String> {
        var out: Set<String> = []
        let strip = CharacterSet(charactersIn: " #\"'")
        var body = text[...]
        if let fm = frontmatterRange(text) {
            body = text[fm.upperBound...]
            var inList = false
            for line in text[fm].split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.lowercased().hasPrefix("tags:") {
                    let value = l.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                    for t in value.split(separator: ",") { out.insert(t.trimmingCharacters(in: strip).lowercased()) }
                    inList = value.isEmpty
                } else if inList && l.hasPrefix("- ") {
                    out.insert(l.dropFirst(2).trimmingCharacters(in: strip).lowercased())
                } else {
                    inList = false
                }
            }
        }
        let b = String(body) as NSString
        for m in inlineTag.matches(in: b as String, range: NSRange(location: 0, length: b.length)) {
            out.insert(b.substring(with: m.range(at: 1)).lowercased())
        }
        out.remove("")
        return out
    }

    /// Compact age for the sidebar: "now", "5m", "3h", "2d", "3w", then "Oct 3" / "Oct 2025".
    static func shortAge(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        if s < 5 * 7 * 86_400 { return "\(Int(s / (7 * 86_400)))w" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.dateFormat = sameYear ? "MMM d" : "MMM yyyy"
        return f.string(from: date)
    }

    // MARK: Names

    /// A file name Obsidian can link to: no path separators or `# ^ [ ] |`.
    static func fileName(for title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var name = String(cleaned.drop { $0 == "." || $0 == " " })
        if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled" : name
    }

    /// `dir/Title.md`, or `Title 2.md`… when the name is taken anywhere in the vault
    /// (Obsidian links by file name only).
    static func uniqueURL(in dir: URL, title: String, taken: Set<String>) -> URL {
        let base = fileName(for: title)
        var name = base, n = 2
        while taken.contains(name.lowercased()) || FileManager.default.fileExists(atPath: dir.appending(path: name + ".md").path) {
            name = "\(base) \(n)"
            n += 1
        }
        return dir.appending(path: name + ".md")
    }

    /// The note's first line of text, stripped of Markdown, as a title.
    static func derivedTitle(_ text: String) -> String? {
        let body = frontmatterRange(text).map { String(text[$0.upperBound...]) } ?? text
        for raw in body.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacing(/^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)/, with: "")
            line = line.replacing(/[*_`=~]|\[\[|\]\]/, with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.count > 60 else { return line }
            let cut = line.prefix(60)
            return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
        }
        return nil
    }

    /// Wiki link target → note: `Name`, `Name|alias`, `Name#Heading`, `folder/Name`.
    static func resolve(link: String, in notes: [NoteFile]) -> NoteFile? {
        var name = link
        if let i = name.firstIndex(where: { $0 == "|" || $0 == "#" || $0 == "^" }) { name = String(name[..<i]) }
        name = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        guard !name.isEmpty else { return nil }
        return notes.first { $0.title == name } ?? notes.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Frontmatter and templates

    static func isoDate(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The leading `---` … `---` block, including both fences and the trailing newline.
    static func frontmatterRange(_ text: String) -> Range<String.Index>? {
        guard text.hasPrefix("---\n") else { return nil }
        let rest = text.index(text.startIndex, offsetBy: 4)
        guard let close = text[rest...].firstMatch(of: /(?m)^(?:---|\.\.\.)[ \t]*(?:\n|$)/) else { return nil }
        return text.startIndex..<close.range.upperBound
    }

    /// A YAML scalar for `title:`: quoted when it would otherwise mean something else.
    static func yamlScalar(_ s: String) -> String {
        let special = CharacterSet(charactersIn: ":#[]{},&*!|>'\"%@`")
        let needsQuotes = s.isEmpty || s.unicodeScalars.contains(where: special.contains)
            || s.first.map { "-?".contains($0) || $0 == " " } == true || s.last == " "
            || ["true", "false", "null", "yes", "no", "~"].contains(s.lowercased()) || Double(s) != nil
        guard needsQuotes else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Fills `{{title}}`, `{{date}}` and `{{time}}`; the title is YAML-quoted inside frontmatter.
    static func render(template: String, title: String, date: Date) -> String {
        let time = String(format: "%02d:%02d", Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date))
        func fill(_ s: Substring, yaml: Bool) -> String {
            s.replacingOccurrences(of: "{{title}}", with: yaml ? yamlScalar(title) : title)
                .replacingOccurrences(of: "{{date}}", with: isoDate(date))
                .replacingOccurrences(of: "{{time}}", with: time)
        }
        guard let fm = frontmatterRange(template) else { return fill(template[...], yaml: false) }
        return fill(template[fm], yaml: true) + fill(template[fm.upperBound...], yaml: false)
    }

    /// Replaces the value of `key:` inside the frontmatter; text without that key is unchanged.
    static func setFrontmatter(_ text: String, key: String, value: String) -> String {
        guard let fm = frontmatterRange(text), let regex = try? Regex("(?m)^\(key):[ \\t]*.*$") else { return text }
        var block = String(text[fm])
        guard let m = block.firstMatch(of: regex) else { return text }
        block.replaceSubrange(m.range, with: "\(key): \(value)")
        return block + text[fm.upperBound...]
    }

    static func bumpUpdated(_ text: String, date: Date) -> String {
        setFrontmatter(text, key: "updated", value: isoDate(date))
    }

    static func setTitle(_ text: String, _ title: String) -> String {
        setFrontmatter(text, key: "title", value: yamlScalar(title))
    }

    // MARK: Files

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads through a file coordinator, which first downloads an evicted iCloud file.
    static func readCoordinated(_ url: URL) -> String? {
        var text: String?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { text = read($0) }
        return text
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

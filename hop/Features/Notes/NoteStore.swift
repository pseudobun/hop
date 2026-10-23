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
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes.map { NoteHit(note: $0) } }
        let cands = notes.map { RankCandidate(id: $0.relativePath, title: $0.title, subtitle: $0.folder, typeWeight: 1) }
        let titled = RootRanker.rank(cands, query: SearchQuery(q), sensitivity: sensitivity)
        var hits = titled.map { NoteHit(note: notes[$0]) }
        let seen = Set(titled)
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for (i, note) in notes.enumerated() where !seen.contains(i) {
            guard let text = contents[note.relativePath],
                  words.allSatisfy({ text.range(of: $0, options: options) != nil }) else { continue }
            hits.append(NoteHit(note: note, snippet: snippet(text, word: words[0])))
        }
        return hits
    }

    /// The trimmed line containing `word`, shortened around the match.
    static func snippet(_ text: String, word: String, width: Int = 90) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let hit = text.range(of: word, options: options) else { return nil }
        let line = text[text.lineRange(for: hit)].trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > width, let inLine = line.range(of: word, options: options) else { return line }
        let offset = line.distance(from: line.startIndex, to: inLine.lowerBound)
        let start = max(0, min(offset - width / 3, line.count - width))
        let from = line.index(line.startIndex, offsetBy: start)
        let to = line.index(from, offsetBy: width)
        return (start > 0 ? "…" : "") + line[from..<to].trimmingCharacters(in: .whitespaces) + (to < line.endIndex ? "…" : "")
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

import CoreServices
import Foundation

/// One file or folder found by Spotlight or by browsing a path.
nonisolated struct FileHit: Sendable, Hashable {
    let path: String
    var isDirectory = false
    var modified: Date?
    var lastUsed: Date?

    var name: String { (path as NSString).lastPathComponent }
    var parent: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
}

/// File search on the Spotlight index (always current, costs hop no memory): a capped
/// MDQuery run off the main thread, then ranked in hop like everything else.
nonisolated enum Spotlight {
    /// A value for a quoted MDQuery string: `"`, `\`, `*` and `?` escaped.
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\"\\*?".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Every word in the file name: as the start of a word in it (fast, uses the index),
    /// or anywhere in it (`substring`, about four times slower).
    static func nameQuery(_ words: [String], substring: Bool = false) -> String {
        words.map { substring ? "kMDItemFSName == \"*\(escape($0))*\"cd" : "kMDItemFSName == \"\(escape($0))*\"cdw" }
            .joined(separator: " && ")
    }

    /// Every word (as a word prefix) in the indexed text of the file.
    static func contentQuery(_ words: [String]) -> String {
        words.map { "kMDItemTextContent == \"\(escape($0))*\"cdw" }.joined(separator: " && ")
    }

    /// Runs a query synchronously (call it off the main thread); at most `limit` results.
    static func run(_ query: String, scopes: [String], limit: Int) -> [FileHit] {
        guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(q, scopes as CFArray, 0)
        MDQuerySetMaxCount(q, limit)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var hits: [FileHit] = []
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let type = MDItemCopyAttribute(item, kMDItemContentType) as? String
            hits.append(FileHit(path: path, isDirectory: type == "public.folder",
                                modified: MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date,
                                lastUsed: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date))
        }
        return hits
    }
}

nonisolated enum FilePaths {
    /// Path components that hide a result (`node_modules`, `.git`, …); a scope inside an
    /// excluded folder (searching `~/Library` itself) still works.
    static func isExcluded(_ path: String, patterns: [String], scopes: [String]) -> Bool {
        let parts = path.split(separator: "/")
        let scopeParts = scopes.map { $0.split(separator: "/").count }.min() ?? 0
        for (i, part) in parts.enumerated() where i >= scopeParts {
            if patterns.contains(where: { $0 == part }) { return true }
        }
        return false
    }

    /// `~/Doc` → (the home folder, "Doc"); `/usr/lo` → (/usr, "lo"); nil if not a path.
    static func split(_ input: String) -> (dir: String, prefix: String)? {
        guard input.hasPrefix("/") || input.hasPrefix("~") else { return nil }
        let expanded = input.expandingTilde
        if input.hasSuffix("/") || input == "~" { return (expanded, "") }
        let ns = expanded as NSString
        return (ns.deletingLastPathComponent.isEmpty ? "/" : ns.deletingLastPathComponent, ns.lastPathComponent)
    }

    /// Entries of `dir` whose name starts with (then contains) `prefix`, folders first.
    static func list(_ dir: String, prefix: String, showHidden: Bool) -> [FileHit] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let p = prefix.lowercased()
        let wanted = names.filter { name in
            (showHidden || p.hasPrefix(".") || !name.hasPrefix(".")) && (p.isEmpty || name.lowercased().contains(p))
        }
        return wanted.map { name -> FileHit in
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let isPackage = isDir.boolValue && ["app", "bundle", "framework", "pkg"].contains((name as NSString).pathExtension)
            return FileHit(path: path, isDirectory: isDir.boolValue && !isPackage)
        }.sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(p), bp = b.name.lowercased().hasPrefix(p)
            if ap != bp { return ap }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What Tab turns the query into: the folder plus "/", or the longest shared prefix.
    static func complete(_ input: String, hits: [FileHit]) -> String? {
        guard let (_, prefix) = split(input) else { return nil }
        let base = input.hasSuffix("/") || input == "~" ? input : String(input.dropLast(prefix.count))
        let sep = base.hasSuffix("/") ? "" : "/"
        let starting = hits.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
        if starting.count == 1 || (starting.first.map { $0.name.caseInsensitiveCompare(prefix) == .orderedSame } ?? false) {
            let h = starting[0]
            return base + sep + h.name + (h.isDirectory ? "/" : "")
        }
        guard let first = starting.first?.name else { return nil }
        var common = first
        for h in starting.dropFirst() {
            while !h.name.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
        }
        return common.count > prefix.count ? base + sep + common : nil
    }

    /// Search score bonus: recently opened or edited files rank higher, deep paths lower.
    static func recency(_ hit: FileHit, now: Date) -> Double {
        let last = [hit.lastUsed, hit.modified].compactMap { $0 }.max() ?? .distantPast
        let days = now.timeIntervalSince(last) / 86_400
        let fresh = days < 1 ? 3.0 : days < 7 ? 2.0 : days < 30 ? 1.0 : 0
        let depth = Double(hit.path.split(separator: "/").count)
        return fresh - depth * 0.05
    }
}

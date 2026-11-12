import AppKit
import UniformTypeIdentifiers

/// One thing on a shelf: a file (by path, never copied), a web link or a piece of text.
/// Images and file promises dropped from apps are saved under `ShelfItem.dropDir` first.
nonisolated struct ShelfItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case file, link, text }

    var id = UUID()
    var kind: Kind
    /// Path for files, the URL for links, the text itself for text.
    var value: String

    static func file(_ path: String) -> ShelfItem { ShelfItem(kind: .file, value: path) }
    static func link(_ url: String) -> ShelfItem { ShelfItem(kind: .link, value: url) }
    static func text(_ text: String) -> ShelfItem { ShelfItem(kind: .text, value: text) }

    /// Images and promised files dropped onto a shelf land here.
    static var dropDir: URL { AppPaths.supportDir.appending(path: "Shelf", directoryHint: .isDirectory) }

    var title: String {
        switch kind {
        case .file:
            return FileManager.default.displayName(atPath: value)
        case .link:
            guard let url = URL(string: value), let host = url.host() else { return value }
            let path = url.path()
            return host + (path == "/" ? "" : path)
        case .text:
            let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    var exists: Bool { kind != .file || FileManager.default.fileExists(atPath: value) }

    /// Two items are the same content regardless of their ids.
    func sameContent(as other: ShelfItem) -> Bool { kind == other.kind && value == other.value }

    /// What a drag out of the shelf or a copy puts on the pasteboard.
    var pasteboardWriter: NSPasteboardWriting {
        switch kind {
        case .file: return URL(fileURLWithPath: value) as NSURL
        case .link: return (URL(string: value) as NSURL?) ?? value as NSString
        case .text: return value as NSString
        }
    }

    /// For AirDrop: URLs for files and links, strings for text.
    var shareObject: Any {
        switch kind {
        case .file: URL(fileURLWithPath: value)
        case .link: URL(string: value) ?? value
        case .text: value
        }
    }

    // MARK: - Reading a drop or the clipboard

    /// Everything on `pasteboard` that can go on a shelf, in this order of preference:
    /// files, web links, image data, text. File promises are read separately (async).
    static func items(from pasteboard: NSPasteboard) -> [ShelfItem] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files.map { .file($0.path) } }
        let links = ((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []).filter { !$0.isFileURL }
        if !links.isEmpty { return links.map { .link($0.absoluteString) } }
        if let image = imageData(from: pasteboard), let url = save(image, ext: "png") { return [.file(url.path)] }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [classify(text)]
        }
        return []
    }

    /// Text that is a single web URL becomes a link.
    static func classify(_ text: String) -> ShelfItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil {
            return .link(trimmed)
        }
        return .text(text)
    }

    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes dropped bytes to a fresh file in `dropDir`.
    static func save(_ data: Data, ext: String) -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let dir = dropDir.appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        let url = dir.appending(path: "Image \(stamp).\(ext)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Dropped-in images and promised files older than `days` that no shelf refers to.
    static func pruneDrops(olderThan days: Int, keeping paths: Set<String>) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: dropDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for dir in dirs {
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let used = paths.contains { $0.hasPrefix(dir.path + "/") }
            if date < cutoff && !used { try? fm.removeItem(at: dir) }
        }
    }
}

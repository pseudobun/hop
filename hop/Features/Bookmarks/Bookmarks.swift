import AppKit

/// Root items for `bookmarks` in the config: ↵ opens the link in the default browser.
enum BookmarkCommands {
    static func items(_ services: Services) -> [Item] {
        let configDir = services.settings.url.deletingLastPathComponent()
        return services.settings.data.bookmarks.compactMap { item(for: $0, configDir: configDir) }
    }

    static func item(for bookmark: HopConfig.Bookmark, configDir: URL) -> Item? {
        let name = bookmark.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let url = url(bookmark.url) else { return nil }
        return Item(id: "bookmark:\(url.absoluteString)", title: name,
                    subtitle: bookmark.subtitle.isEmpty ? display(url) : bookmark.subtitle,
                    aliases: bookmark.aliases, icon: icon(bookmark, configDir: configDir), accessory: "Bookmark",
                    actions: [
                        Action(title: "Open Bookmark") {
                            NSWorkspace.shared.open(url)
                            return .dismiss
                        },
                        Action(title: "Copy URL", shortcut: .cmd("c", .shift)) {
                            Pasteboard.copy(url.absoluteString)
                            return .dismissWithHUD("Copied URL")
                        },
                    ])
    }

    /// "example.com" gets https://; anything with a scheme is taken as is.
    static func url(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let u = URL(string: s.contains("://") ? s : "https://" + s), u.host() != nil else { return nil }
        return u
    }

    /// The URL without its scheme or a trailing slash, e.g. "192.168.1.50:8123".
    static func display(_ url: URL) -> String {
        var s = url.absoluteString
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// An image file (relative to the config folder, ~/ or absolute), an SF Symbol on a
    /// tile, or an emoji; a bookmark tile when empty or the file is missing.
    static func icon(_ bookmark: HopConfig.Bookmark, configDir: URL) -> ItemIcon {
        let tint = color(bookmark.color) ?? Theme.info
        let fallback = ItemIcon.tile("bookmark.fill", tint)
        let value = bookmark.icon.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return fallback }
        if imageExtensions.contains((value as NSString).pathExtension.lowercased()) {
            let expanded = value.expandingTilde
            let path = expanded.hasPrefix("/") ? expanded : configDir.appending(path: expanded).path
            return FileManager.default.fileExists(atPath: path) ? .imageFile(path) : fallback
        }
        if NSImage(systemSymbolName: value, accessibilityDescription: nil) != nil { return .tile(value, tint) }
        return value.count <= 2 ? .emoji(value) : fallback
    }

    private static let imageExtensions: Set<String> = [
        "svg", "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "icns", "ico", "pdf", "bmp",
    ]

    /// "#18bcf2" or "18bcf2".
    static func color(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

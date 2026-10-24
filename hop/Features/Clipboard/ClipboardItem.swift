import Foundation

/// What a clipboard entry holds, as shown in the list and the preview.
nonisolated enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text, link, color, image, file

    var label: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .color: "Color"
        case .image: "Image"
        case .file: "File"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// One clipboard history entry. Image and rich-text payloads live in files next to
/// the index; `text` is also the plain-text fallback for everything.
nonisolated struct ClipboardItem: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: ClipboardKind
    /// Plain text (text, link, color), file paths joined by newlines, or empty for images.
    var text: String = ""
    /// File names in the store folder.
    var imageFile: String?
    var rtfFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var bytes: Int = 0
    var filePaths: [String]?
    var sourceBundleID: String?
    var sourceName: String?
    var firstCopied: Date = Date()
    var lastCopied: Date = Date()
    var timesCopied = 1
    var pinned = false
    /// Content fingerprint for de-duplication.
    var hash: String

    /// One line for the list.
    var title: String {
        switch kind {
        case .image:
            if let w = imageWidth, let h = imageHeight { return "Image (\(w)×\(h))" }
            return "Image"
        case .file:
            let paths = filePaths ?? []
            let first = (paths.first.map { ($0 as NSString).lastPathComponent }) ?? "File"
            return paths.count > 1 ? "\(first) +\(paths.count - 1)" : first
        default:
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        }
    }

    /// Search: every word must appear in the text, file names, source app or kind.
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [text, title, sourceName ?? "", kind.label, (filePaths ?? []).joined(separator: " ")].joined(separator: "\n")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

nonisolated extension ClipboardItem {
    private enum Keys: String, CodingKey {
        case id, kind, text, imageFile, rtfFile, imageWidth, imageHeight, bytes, filePaths, sourceBundleID, sourceName
        case firstCopied, lastCopied, timesCopied, pinned, hash
    }

    /// Lenient: fields added later fall back to defaults instead of failing the whole history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(ClipboardKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        rtfFile = try c.decodeIfPresent(String.self, forKey: .rtfFile)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        firstCopied = try c.decodeIfPresent(Date.self, forKey: .firstCopied) ?? Date()
        lastCopied = try c.decodeIfPresent(Date.self, forKey: .lastCopied) ?? firstCopied
        timesCopied = try c.decodeIfPresent(Int.self, forKey: .timesCopied) ?? 1
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? id
    }
}

/// Text statistics for the preview's information block.
nonisolated struct TextStats: Equatable, Sendable {
    let characters: Int
    let words: Int
    let lines: Int

    init(_ text: String) {
        characters = text.count
        words = text.split { $0.isWhitespace || $0.isNewline }.count
        lines = text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }
}

/// A colour written as text: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()`, `hsl()`/`hsla()`.
nonisolated struct ClipColor: Equatable, Sendable {
    /// sRGB components 0…1.
    let red: Double, green: Double, blue: Double, alpha: Double

    static func parse(_ raw: String) -> ClipColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count <= 40 else { return nil }
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            guard hex.allSatisfy(\.isHexDigit), [3, 4, 6, 8].contains(hex.count) else { return nil }
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            let v = UInt64(hex, radix: 16) ?? 0
            let has = hex.count == 8
            let r = Double((v >> (has ? 24 : 16)) & 0xff), g = Double((v >> (has ? 16 : 8)) & 0xff)
            let b = Double((v >> (has ? 8 : 0)) & 0xff), a = has ? Double(v & 0xff) / 255 : 1
            return ClipColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let fn = s[..<open].trimmingCharacters(in: .whitespaces)
        let args = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .split { $0 == "," || $0 == " " || $0 == "/" }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func num(_ a: String, scale: Double) -> Double? {
            if a.hasSuffix("%") { return Double(a.dropLast()).map { $0 / 100 } }
            return Double(a).map { $0 / scale }
        }
        switch fn {
        case "rgb", "rgba":
            guard args.count == 3 || args.count == 4,
                  let r = num(args[0], scale: 255), let g = num(args[1], scale: 255), let b = num(args[2], scale: 255) else { return nil }
            let a = args.count == 4 ? num(args[3], scale: 1) : 1
            guard let a, [r, g, b, a].allSatisfy({ (0...1).contains($0) }) else { return nil }
            return ClipColor(red: r, green: g, blue: b, alpha: a)
        case "hsl", "hsla":
            guard args.count == 3 || args.count == 4, let h = Double(args[0].replacingOccurrences(of: "deg", with: "")),
                  let sat = num(args[1], scale: 100), let l = num(args[2], scale: 100) else { return nil }
            let a = args.count == 4 ? num(args[3], scale: 1) : 1
            guard let a, (0...1).contains(sat), (0...1).contains(l), (0...1).contains(a) else { return nil }
            let (r, g, b) = hslToRGB(h, sat, l)
            return ClipColor(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }

    private func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }

    var hex: String {
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha < 1 ? base + String(format: "%02X", byte(alpha)) : base
    }

    var rgb: String {
        alpha < 1 ? "rgba(\(byte(red)), \(byte(green)), \(byte(blue)), \(String(format: "%.2g", alpha)))"
            : "rgb(\(byte(red)), \(byte(green)), \(byte(blue)))"
    }

    var hsl: String {
        let mx = max(red, green, blue), mn = min(red, green, blue), l = (mx + mn) / 2, d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = d / (1 - abs(2 * l - 1))
            h = switch mx {
            case red: 60 * ((green - blue) / d).truncatingRemainder(dividingBy: 6)
            case green: 60 * ((blue - red) / d + 2)
            default: 60 * ((red - green) / d + 4)
            }
            if h < 0 { h += 360 }
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

/// How text from the clipboard is shown: link, colour, Markdown, code or prose.
nonisolated enum ClipboardClassifier {
    static func kind(of text: String) -> ClipboardKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClipColor.parse(t) != nil { return .color }
        if isLink(t) { return .link }
        return .text
    }

    static func isLink(_ t: String) -> Bool {
        guard !t.contains(where: \.isWhitespace), t.count < 2048, let url = URL(string: t), let scheme = url.scheme?.lowercased()
        else { return false }
        switch scheme {
        case "http", "https": return url.host?.contains(".") == true || url.host == "localhost"
        case "mailto", "tel", "ssh", "ftp", "obsidian", "raycast", "x-apple.systempreferences": return true
        default: return false
        }
    }

    enum Presentation: Equatable { case markdown, code, prose }

    static func presentation(of text: String) -> Presentation {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.contains("```") { return .markdown }
        let mdLines = lines.filter { l in
            l.range(of: #"^\s*(#{1,6}\s|[-*+]\s|\d+\.\s|>\s|- \[[ xX]\])"#, options: .regularExpression) != nil
        }.count
        let inline = text.range(of: #"(\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\s]+\)|\[\[[^\]\n]+\]\])"#, options: .regularExpression) != nil
        if mdLines >= 2 || (mdLines >= 1 && lines.count <= 3 && lines.first.map { $0.hasPrefix("#") } == true) || inline {
            return .markdown
        }
        let codeHints = lines.filter { l in
            l.range(of: #"[{};]\s*$|^\s*(func|let|var|const|import|def|class|return|if|for|fn|pub|struct|package)\b|=>|::|\$\(|^\s{2,}\S"#,
                    options: .regularExpression) != nil
        }.count
        if lines.count >= 2 && Double(codeHints) / Double(lines.count) >= 0.4 { return .code }
        if lines.count == 1 && text.range(of: #"^\s*(\$ |sudo |git |cd |ls |brew |just |kubectl |ssh |curl |npm |pnpm )"#, options: .regularExpression) != nil {
            return .code
        }
        return .prose
    }
}

/// Sections of the history list.
nonisolated enum ClipboardGroups {
    static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if let w = calendar.date(byAdding: .day, value: -7, to: now), date > w { return "This Week" }
        if let m = calendar.date(byAdding: .day, value: -30, to: now), date > m { return "This Month" }
        return "Older"
    }
}

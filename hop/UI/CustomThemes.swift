import AppKit

/// A theme file in `~/.config/hop/themes/` (JSON5). Every key is optional: what is left out
/// comes from `base`, a built-in theme. `hop themes template` prints a commented one.
nonisolated struct ThemeFile: Decodable, Equatable, Sendable {
    var name: String?
    var description: String?
    var base: String?
    var light: Bool?
    /// Palette keys (`Theme.Palette.keys`) to "#rgb", "#rrggbb" or "#rrggbbaa".
    var colors: [String: String]?
    var fonts: Fonts?
    var monoLabels: Bool?
    var tracking: Double?
    var titleWeight: Double?

    nonisolated struct Fonts: Decodable, Equatable, Sendable {
        var sans: String?
        var heading: String?
        var mono: String?
    }
}

/// Loads, checks and writes the user's themes. The file name (without its extension) is the
/// theme's id, the value `general.theme` takes; font files beside them are registered for them.
enum CustomThemes {
    static let extensions: Set<String> = ["json5", "json"]
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// `themes/` beside the config file.
    static func folder(beside config: URL) -> URL {
        config.deletingLastPathComponent().appending(path: "themes", directoryHint: .isDirectory)
    }

    struct Loaded {
        var themes: [(name: Theme.Name, spec: Theme.Spec)] = []
        var fonts: [URL] = []
        /// One line per problem, naming the file; a theme with problems still loads what it can.
        var issues: [String] = []
        /// Every file read, by path, to tell a real change from a save that changed nothing.
        var signature: [String: Data] = [:]
    }

    /// Reads every theme in `folder`, sorted by label. A missing folder has none.
    static func load(from folder: URL) -> Loaded {
        var loaded = Loaded()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles])
        else { return loaded }
        var files: [URL] = []
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            if fontExtensions.contains(ext) {
                loaded.fonts.append(url)
                loaded.signature[url.path] = Data()
            }
            // Themes sit at the top; subfolders are for their fonts.
            else if extensions.contains(ext), url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                files.append(url)
            }
        }
        var seen: Set<Theme.Name> = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = Theme.Name(rawValue: url.deletingPathExtension().lastPathComponent)
            if name.isBuiltIn {
                loaded.issues.append("\(url.lastPathComponent): \"\(name.rawValue)\" is a built-in theme, rename the file")
                continue
            }
            if !seen.insert(name).inserted {
                loaded.issues.append("\(url.lastPathComponent): another file is already theme \"\(name.rawValue)\"")
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                loaded.signature[url.path] = data
                let file = try decode(data)
                let (spec, issues) = spec(from: file, id: name, url: url)
                loaded.themes.append((name, spec))
                loaded.issues += issues.map { "\(url.lastPathComponent): \($0)" }
            } catch {
                loaded.issues.append("\(url.lastPathComponent): \(message(for: error))")
            }
        }
        loaded.themes.sort { $0.spec.label.localizedStandardCompare($1.spec.label) == .orderedAscending }
        return loaded
    }

    static func decode(_ data: Data) throws -> ThemeFile {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(ThemeFile.self, from: data)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let ctx) where ctx.codingPath.isEmpty:
            "not valid JSON5 (\((ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? ctx.debugDescription))"
        case DecodingError.typeMismatch(let type, let ctx):
            "\(ConfigDiagnostics.display(ctx.codingPath.map(\.stringValue))) should be \(type == String.self ? "a string" : "a \(type)")"
        case let error as DecodingError:
            String(describing: error)
        default:
            error.localizedDescription
        }
    }

    /// The spec a file describes, on top of its base, and what in it was ignored.
    static func spec(from file: ThemeFile, id: Theme.Name, url: URL? = nil) -> (Theme.Spec, [String]) {
        var issues: [String] = []
        var baseName = Theme.Name.og
        if let raw = file.base {
            let name = Theme.Name(rawValue: raw)
            if name.isBuiltIn { baseName = name } else {
                issues.append("base \"\(raw)\" is not a built-in theme, using \"og\"")
            }
        }
        let base = Theme.builtIn(baseName)!

        var overrides: [String: NSColor] = [:]
        for (key, value) in file.colors ?? [:] {
            guard Theme.Palette.keys.contains(key) else {
                let hint = ConfigDiagnostics.suggestion(for: key, among: Theme.Palette.keys).map { ", did you mean \"\($0)\"?" } ?? ""
                issues.append("unknown colour \"\(key)\"\(hint)")
                continue
            }
            guard let color = color(hex: value) else {
                issues.append("colors.\(key): \"\(value)\" is not a colour (\"#rrggbb\" or \"#rrggbbaa\")")
                continue
            }
            overrides[key] = color
        }

        func face(_ value: String?, _ fallback: Theme.Face) -> Theme.Face {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
            switch value.lowercased() {
            case "system": return .system
            case "system-mono", "systemmono", "mono": return .systemMono
            default: return .named(value)
            }
        }

        let label = file.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? id.rawValue
        let spec = Theme.Spec(
            label: label,
            description: file.description ?? "Your theme, from \(url?.lastPathComponent ?? id.rawValue).",
            light: file.light ?? base.light,
            palette: Theme.Palette(base: base.palette, overrides: overrides),
            sans: face(file.fonts?.sans, base.sans),
            heading: face(file.fonts?.heading, base.heading),
            mono: face(file.fonts?.mono, base.mono),
            monoLabels: file.monoLabels ?? base.monoLabels,
            tracking: file.tracking.map { CGFloat($0) } ?? base.tracking,
            titleWeight: file.titleWeight.map { CGFloat(min(max($0, 100), 900)) } ?? base.titleWeight,
            file: url, base: baseName)
        return (spec, issues)
    }

    /// "#rgb", "#rgba", "#rrggbb" or "#rrggbbaa" (the # is optional), in sRGB.
    nonisolated static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count <= 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        func byte(_ i: UInt64) -> CGFloat { CGFloat((v >> (i + shift)) & 0xFF) / 255 }
        return NSColor(srgbRed: byte(16), green: byte(8), blue: byte(0), alpha: hasAlpha ? CGFloat(v & 0xFF) / 255 : 1)
    }

    /// "#rrggbb", or "#rrggbbaa" when not opaque.
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ x: CGFloat) -> String { String(format: "%02x", Int((min(max(x, 0), 1) * 255).rounded())) }
        let rgb = "#" + byte(c.redComponent) + byte(c.greenComponent) + byte(c.blueComponent)
        return c.alphaComponent < 0.999 ? rgb + byte(c.alphaComponent) : rgb
    }

    // MARK: Writing

    /// A commented theme file with every colour of `spec` written out, ready to edit.
    static func template(name: String, from spec: Theme.Spec, base: Theme.Name) -> String {
        let p = spec.palette
        func line(_ key: String, _ comment: String? = nil) -> String {
            "    \(key): \"\(hex(p[key]!))\",\(comment.map { " // \($0)" } ?? "")"
        }
        func fontName(_ face: Theme.Face) -> String? {
            switch face {
            case .system: "system"
            case .systemMono: "system-mono"
            case .named(let name): name
            case .variable, .cuts: nil // bundled with hop: inherited from base
            }
        }
        func fontLine(_ key: String, _ face: Theme.Face, _ example: String) -> String {
            if let name = fontName(face) { return "    \(key): \(ConfigEdit.literal(name))," }
            return "    // \(key): \(ConfigEdit.literal(example)),"
        }
        return """
        // A hop theme (JSON5: comments and trailing commas are fine).
        // Keep it in ~/.config/hop/themes/: the file name is the theme's id, so `theme: "nord"` in
        // config.json5 picks nord.json5. The Theme command lists it; saved changes apply at once.
        {
          name: \(ConfigEdit.literal(name)),
          description: \(ConfigEdit.literal("Based on \(Theme.spec(base).label).")),
          // Every key left out comes from this built-in theme:
          // "og", "og-light", "modern", "solarpunk" or "cyberpunk"
          base: \(ConfigEdit.literal(base.rawValue)),
          // Light themes get light window chrome and controls
          light: \(spec.light),
          // "#rgb", "#rrggbb" or "#rrggbbaa"
          colors: {
            // Surfaces
        \(line("background", "window"))
        \(line("card", "selected row, panels"))
        \(line("muted", "subtle fills"))
        \(line("foreground", "text"))
        \(line("mutedForeground", "secondary text"))
        \(line("border"))
        \(line("ring", "focus"))
        \(line("primary", "accent"))
            // Status, one meaning each
        \(line("good", "healthy, done"))
        \(line("warn", "needs attention"))
        \(line("info", "in progress, selected"))
        \(line("destructive", "failed, bad"))
            // Icons and charts
        \(line("chart1"))
        \(line("chart2"))
        \(line("chart3"))
        \(line("chart4"))
        \(line("chart5"))
          },
          // An installed font's family ("Inter") or PostScript name ("Inter-Medium"), "system" or
          // "system-mono". Font files (.ttf, .otf) anywhere in the themes folder are loaded too.
          fonts: {
        \(fontLine("sans", spec.sans, "Inter"))
        \(fontLine("heading", spec.heading, "Inter"))
        \(fontLine("mono", spec.mono, "JetBrains Mono"))
          },
          // Labels and meta lines in the mono font, uppercase and tracked by `tracking` em
          monoLabels: \(spec.monoLabels),
          tracking: \(trim(spec.tracking)),
          // Weight of a screen's title, 100–900
          titleWeight: \(trim(spec.titleWeight)),
        }

        """
    }

    private static func trim(_ x: CGFloat) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%g", Double(x))
    }

    /// `examples/theme.json5` and `hop themes template`: OG, written out.
    static var defaultTemplate: String {
        template(name: "My Theme", from: Theme.builtIn(.og)!, base: .og)
    }

    /// A file name in `folder` that is not taken: `my-theme.json5`, `my-theme-2.json5`…
    static func freeURL(in folder: URL, stem: String) -> URL {
        let fm = FileManager.default
        var n = 1
        while true {
            let id = n == 1 ? stem : "\(stem)-\(n)"
            let url = folder.appending(path: "\(id).json5")
            if !fm.fileExists(atPath: url.path), !Theme.Name(rawValue: id).isBuiltIn { return url }
            n += 1
        }
    }

    /// "My Theme!" → "my-theme".
    static func slug(_ text: String) -> String {
        let parts = text.lowercased().split { !($0.isLetter || $0.isNumber) }
        return parts.isEmpty ? "theme" : parts.joined(separator: "-")
    }

    /// Writes a new theme from `name`'s spec into `folder` and returns it.
    static func create(in folder: URL, from name: Theme.Name) throws -> URL {
        let spec = Theme.spec(name)
        let base = name.isBuiltIn ? name : (spec.base ?? .og)
        let label = "My \(spec.label)"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = freeURL(in: folder, stem: slug(label))
        try template(name: label, from: spec, base: base).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Copies theme and font files into `folder` after checking each theme parses. Returns the
    /// themes it added; a file whose name is taken gets a free one.
    static func importFiles(_ urls: [URL], into folder: URL) throws -> [Theme.Name] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [Theme.Name] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if fontExtensions.contains(ext) {
                let target = folder.appending(path: url.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
                continue
            }
            guard extensions.contains(ext) else { throw ImportError.unsupported(url.lastPathComponent) }
            let data = try Data(contentsOf: url)
            do { _ = try decode(data) } catch { throw ImportError.invalid(url.lastPathComponent, message(for: error)) }
            let stem = slug(url.deletingPathExtension().lastPathComponent)
            let target = freeURL(in: folder, stem: stem)
            try data.write(to: target, options: .atomic)
            added.append(Theme.Name(rawValue: target.deletingPathExtension().lastPathComponent))
        }
        return added
    }

    enum ImportError: LocalizedError {
        case unsupported(String)
        case invalid(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let file): "\(file) is not a theme (.json5) or font (.ttf, .otf)"
            case .invalid(let file, let why): "\(file): \(why)"
            }
        }
    }
}

extension Theme.Palette {
    /// The JSON keys of a palette, in the order theme files list them.
    static let keys = ["background", "card", "muted", "foreground", "mutedForeground", "border", "ring", "primary",
                       "good", "warn", "info", "destructive", "chart1", "chart2", "chart3", "chart4", "chart5"]

    subscript(key: String) -> NSColor? {
        switch key {
        case "background": background
        case "card": card
        case "muted": muted
        case "foreground": foreground
        case "mutedForeground": mutedForeground
        case "border": border
        case "ring": ring
        case "primary": primary
        case "good": good
        case "warn": warn
        case "info": info
        case "destructive": destructive
        case "chart1": chart1
        case "chart2": chart2
        case "chart3": chart3
        case "chart4": chart4
        case "chart5": chart5
        default: nil
        }
    }

    /// `base` with the colours in `overrides` (by key) swapped in.
    init(base: Theme.Palette, overrides: [String: NSColor]) {
        func c(_ key: String) -> NSColor { overrides[key] ?? base[key]! }
        self.init(background: c("background"), card: c("card"), muted: c("muted"), foreground: c("foreground"),
                  mutedForeground: c("mutedForeground"), border: c("border"), ring: c("ring"), primary: c("primary"),
                  good: c("good"), warn: c("warn"), info: c("info"), destructive: c("destructive"),
                  chart1: c("chart1"), chart2: c("chart2"), chart3: c("chart3"), chart4: c("chart4"), chart5: c("chart5"))
    }
}

/// Calls `onChange` (debounced) when anything in a folder changes: a file added, removed or
/// replaced shows up on the folder, an in-place write only on the file, so each file is watched
/// too. A missing folder is watched from its parent until it appears.
final class FolderWatcher {
    let folder: URL
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    init(folder: URL, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onChange = onChange
        rewatch()
    }

    deinit { sources.forEach { $0.cancel() } }

    func stop() {
        pending?.cancel()
        sources.forEach { $0.cancel() }
        sources = []
    }

    private func rewatch() {
        sources.forEach { $0.cancel() }
        sources = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else {
            if let s = source(folder.deletingLastPathComponent().path, [.write]) { sources.append(s) }
            return
        }
        if let s = source(folder.path, [.write, .rename, .delete]) { sources.append(s) }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where CustomThemes.extensions.contains(file.pathExtension.lowercased()) {
            if let s = source(file.path, [.write, .extend, .rename, .delete]) { sources.append(s) }
        }
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            rewatch()
            onChange()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

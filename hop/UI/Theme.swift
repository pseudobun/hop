import AppKit
import CoreText

/// hop's design system, translated to AppKit: dense and quiet; colours are tokens only.
/// Every theme sets a palette, fonts and label recipe; the set mirrors olympus-dashboard's
/// (OG, OG Light, Solarpunk, Cyberpunk) plus Modern, and users add their own (CustomThemes).
enum Theme {
    typealias Name = HopConfig.General.ThemeName

    /// Set once at launch from `general.theme`; views read it while they are built.
    nonisolated(unsafe) static var variant: Name = .og
    /// Themes from `~/.config/hop/themes/`, by file name, in the order the picker lists them.
    private(set) static var custom: [(name: Name, spec: Spec)] = []
    /// Bumped whenever the custom themes are loaded again, so views built in an edited theme
    /// can tell they are stale even though its name did not change.
    private(set) static var revision = 0
    /// Every theme the picker offers: built-in ones first, then the user's.
    static var all: [Name] { Name.builtIn + custom.map(\.name) }
    static func exists(_ name: Name) -> Bool { name.isBuiltIn || custom.contains { $0.name == name } }

    static func setCustom(_ themes: [(name: Name, spec: Spec)]) {
        custom = themes
        revision += 1
        fonts.removeAll()
    }
    static var isModern: Bool { variant == .modern }
    static var isLight: Bool { spec(variant).light }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static var palette: Palette { spec(variant).palette }

    // Surfaces
    static var background: NSColor { palette.background }
    static var card: NSColor { palette.card }
    static var muted: NSColor { palette.muted }
    static var foreground: NSColor { palette.foreground }
    static var mutedForeground: NSColor { palette.mutedForeground }
    static var border: NSColor { palette.border }
    static var ring: NSColor { palette.ring }
    static var primary: NSColor { palette.primary }

    // Status tones: one meaning each
    static var good: NSColor { palette.good } // healthy, done
    static var warn: NSColor { palette.warn } // needs attention
    static var info: NSColor { palette.info } // in progress, selected
    static var destructive: NSColor { palette.destructive } // failed, bad

    // Categorical
    static var chart1: NSColor { palette.chart1 }
    static var chart2: NSColor { palette.chart2 }
    static var chart3: NSColor { palette.chart3 }
    static var chart4: NSColor { palette.chart4 }
    static var chart5: NSColor { palette.chart5 }

    /// A faint wash of the foreground: hover fills, inline code, search boxes.
    static func wash(_ alpha: CGFloat) -> NSColor { foreground.withAlphaComponent(alpha) }

    /// Aqua for light themes, Dark Aqua for the rest.
    static var appearance: NSAppearance? { NSAppearance(named: isLight ? .aqua : .darkAqua) }

    // MARK: Themes

    struct Palette {
        let background, card, muted, foreground, mutedForeground, border, ring, primary: NSColor
        let good, warn, info, destructive: NSColor
        let chart1, chart2, chart3, chart4, chart5: NSColor
    }

    /// A font family: one variable file driven by its wght axis, or static cuts by weight.
    enum Face {
        case variable(String, axes: [Int: CGFloat] = [:])
        case cuts([(weight: CGFloat, postScript: String)])
        case system
        case systemMono
        /// A user's font: an installed family ("Inter") or PostScript name ("Inter-Medium").
        case named(String)
    }

    struct Spec {
        let label: String
        let description: String
        let light: Bool
        let palette: Palette
        let sans, heading, mono: Face
        /// Labels and meta lines in mono, uppercase labels tracked by `tracking` em.
        let monoLabels: Bool
        let tracking: CGFloat
        /// Weight of the one title on a screen.
        let titleWeight: CGFloat
        /// A custom theme's file and the built-in theme it starts from; nil for built-in ones.
        var file: URL? = nil
        var base: Name? = nil
    }

    /// The theme's spec; a name that is neither built in nor a custom theme falls back to OG.
    static func spec(_ name: Name) -> Spec {
        builtIn(name) ?? custom.first { $0.name == name }?.spec ?? og
    }

    static func builtIn(_ name: Name) -> Spec? {
        switch name {
        case .og: og
        case .ogLight: ogLight
        case .modern: modern
        case .solarpunk: solarpunk
        case .cyberpunk: cyberpunk
        default: nil
        }
    }

    private static let outfit = Face.variable("Outfit-Thin")
    private static let geist = Face.variable("GeistMono-Regular")

    /// The original: warm near-black, high contrast, green accent.
    private static let og = Spec(
        label: "OG", description: "The original. Olive-black, Outfit and Geist Mono.", light: false,
        palette: Palette(
            background: rgb(0.047, 0.047, 0.035), // #0c0c09
            card: rgb(0.1135, 0.1135, 0.0861),
            muted: rgb(0.1686, 0.1687, 0.133),
            foreground: rgb(0.985, 0.985, 0.976),
            mutedForeground: rgb(0.6706, 0.6706, 0.612),
            border: NSColor.white.withAlphaComponent(0.10),
            ring: rgb(0.486, 0.486, 0.4035),
            primary: rgb(0.0058, 0.4015, 0.1886),
            good: rgb(0.2614, 0.8371, 0.5616),
            warn: rgb(0.989, 0.7105, 0.1729),
            info: rgb(0.3348, 0.7215, 0.9707),
            destructive: rgb(1.0, 0.3912, 0.4039),
            chart1: rgb(0.0, 0.8012, 0.5289),
            chart2: rgb(1.0, 0.6865, 0.1142),
            chart3: rgb(0.0, 0.688, 1.0),
            chart4: rgb(1.0, 0.3469, 0.4331),
            chart5: rgb(0.6729, 0.4741, 1.0)),
        sans: outfit, heading: outfit, mono: geist, monoLabels: true, tracking: 0.18, titleWeight: 500)

    /// The original, in daylight.
    private static let ogLight = Spec(
        label: "OG Light", description: "The original, in daylight.", light: true,
        palette: Palette(
            background: rgb(1, 1, 1),
            card: rgb(0.985, 0.985, 0.976), // #fbfbf9
            muted: rgb(0.957, 0.957, 0.942), // #f4f4f0
            foreground: rgb(0.047, 0.047, 0.036), // #0c0c09
            mutedForeground: rgb(0.452, 0.451, 0.370), // #73735e
            border: rgb(0.910, 0.910, 0.890), // #e8e8e3
            ring: rgb(0.671, 0.671, 0.612),
            primary: rgb(0.000, 0.510, 0.210), // #008236
            good: rgb(0.000, 0.535, 0.295),
            warn: rgb(0.661, 0.382, 0.000),
            info: rgb(0.000, 0.476, 0.749),
            destructive: rgb(0.867, 0.000, 0.000),
            chart1: rgb(0.000, 0.693, 0.443),
            chart2: rgb(0.922, 0.586, 0.000),
            chart3: rgb(0.000, 0.612, 0.934),
            chart4: rgb(0.987, 0.258, 0.364),
            chart5: rgb(0.579, 0.371, 0.978)),
        sans: outfit, heading: outfit, mono: geist, monoLabels: true, tracking: 0.18, titleWeight: 500)

    /// Warm charcoal instead of black, brighter secondary text, softer tones, clay accent.
    private static let modern = Spec(
        label: "Modern", description: "Warm charcoal, system fonts, softer contrast.", light: false,
        palette: Palette(
            background: rgb(0.149, 0.149, 0.141), // #262624
            card: rgb(0.188, 0.188, 0.180), // #30302e
            muted: rgb(0.235, 0.233, 0.222),
            foreground: rgb(0.980, 0.976, 0.961), // #faf9f5
            mutedForeground: rgb(0.760, 0.753, 0.714), // #c2c0b6
            border: NSColor.white.withAlphaComponent(0.09),
            ring: rgb(0.45, 0.445, 0.42),
            primary: rgb(0.851, 0.467, 0.341), // #d97757
            good: rgb(0.475, 0.808, 0.596),
            warn: rgb(0.906, 0.690, 0.365),
            info: rgb(0.851, 0.467, 0.341),
            destructive: rgb(0.941, 0.478, 0.455),
            chart1: rgb(0.380, 0.780, 0.620),
            chart2: rgb(0.906, 0.690, 0.365),
            chart3: rgb(0.420, 0.660, 0.930),
            chart4: rgb(0.925, 0.490, 0.510),
            chart5: rgb(0.690, 0.560, 0.940)),
        sans: .system, heading: .system, mono: .systemMono, monoLabels: false, tracking: 0, titleWeight: 600)

    /// Sunlit paper, moss and brass; Nunito, Fraunces titles, DM Mono.
    private static let solarpunk = Spec(
        label: "Solarpunk", description: "Sunlit paper, moss and brass. Fraunces titles, Nunito, DM Mono.", light: true,
        palette: Palette(
            background: rgb(0.965, 0.945, 0.882), // #f6f1e1
            card: rgb(0.998, 0.988, 0.947), // #fffcf1
            muted: rgb(0.940, 0.925, 0.843), // #f0ecd7
            foreground: rgb(0.072, 0.177, 0.098), // #122d19
            mutedForeground: rgb(0.330, 0.404, 0.291), // #54674a
            border: rgb(0.855, 0.837, 0.720), // #dad5b8
            ring: rgb(0.380, 0.589, 0.334),
            primary: rgb(0.153, 0.461, 0.185), // #27762f
            good: rgb(0.112, 0.464, 0.206),
            warn: rgb(0.610, 0.353, 0.000),
            info: rgb(0.000, 0.446, 0.541),
            destructive: rgb(0.771, 0.183, 0.084),
            chart1: rgb(0.226, 0.591, 0.260),
            chart2: rgb(0.840, 0.614, 0.010),
            chart3: rgb(0.000, 0.574, 0.625),
            chart4: rgb(0.828, 0.366, 0.192),
            chart5: rgb(0.577, 0.358, 0.627)),
        sans: .variable("Nunito-ExtraLight"),
        heading: .variable("Fraunces-Thin", axes: [0x534F_4654: 100, 0x574F_4E4B: 1]), // SOFT, WONK
        mono: .cuts([(400, "DMMono-Regular"), (500, "DMMono-Medium")]),
        monoLabels: true, tracking: 0.12, titleWeight: 600)

    /// Neon magenta and cyan on violet-black; Chakra Petch, Orbitron titles, Share Tech Mono.
    private static let cyberpunk = Spec(
        label: "Cyberpunk", description: "Neon on night glass. Chakra Petch, Orbitron titles.", light: false,
        palette: Palette(
            background: rgb(0.035, 0.024, 0.059), // #09060f
            card: rgb(0.060, 0.049, 0.116), // #0f0c1d
            muted: rgb(0.103, 0.091, 0.172), // #1a172c
            foreground: rgb(0.848, 0.961, 0.966), // #d8f5f6
            mutedForeground: rgb(0.521, 0.735, 0.788), // #85bbc9
            border: rgb(0.000, 0.847, 0.883, 0.22),
            ring: rgb(0.000, 0.923, 0.925),
            primary: rgb(0.951, 0.144, 0.770), // #f325c4
            good: rgb(0.338, 0.958, 0.529),
            warn: rgb(0.976, 0.858, 0.218),
            info: rgb(0.105, 0.899, 0.935),
            destructive: rgb(1.000, 0.225, 0.403),
            chart1: rgb(0.000, 0.910, 0.912),
            chart2: rgb(0.968, 0.223, 0.789),
            chart3: rgb(0.976, 0.858, 0.218),
            chart4: rgb(0.305, 0.931, 0.504),
            chart5: rgb(0.626, 0.423, 1.000)),
        sans: .cuts([(300, "ChakraPetch-Light"), (400, "ChakraPetch-Regular"), (500, "ChakraPetch-Medium"),
                     (600, "ChakraPetch-SemiBold"), (700, "ChakraPetch-Bold")]),
        heading: .variable("Orbitron-Regular"),
        mono: .cuts([(400, "ShareTechMono-Regular")]),
        monoLabels: true, tracking: 0.22, titleWeight: 600)

    // MARK: Fonts

    private static let wghtAxis = 0x7767_6874 // 'wght'

    private struct FontKey: Hashable {
        let postScript: String
        let size: CGFloat
        let weight: CGFloat
    }

    /// Resolving a variable font instance is slow and cells ask for fonts on every configure.
    private static var fonts: [FontKey: NSFont] = [:]

    static func registerFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        fonts.removeAll() // drop fallbacks resolved before registration
    }

    /// Font files a user keeps beside their themes; one already registered is skipped quietly.
    static func registerFonts(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        fonts.removeAll()
    }

    private static func cached(_ key: FontKey, _ make: () -> NSFont) -> NSFont {
        if let font = fonts[key] { return font }
        let font = make()
        fonts[key] = font
        return font
    }

    /// The registered font, or nil when the name resolved to a substitute.
    private static func named(_ postScript: String, _ d: NSFontDescriptor, _ size: CGFloat) -> NSFont? {
        NSFont(descriptor: d, size: size)
            .flatMap { $0.fontName.lowercased().contains(postScript.prefix(4).lowercased()) ? $0 : nil }
    }

    private static func systemWeight(_ w: CGFloat) -> NSFont.Weight {
        switch w {
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<675: .semibold
        default: .bold
        }
    }

    private static func font(_ face: Face, _ size: CGFloat, _ weight: CGFloat, mono: Bool) -> NSFont {
        let fallback = { mono ? NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight(weight))
            : NSFont.systemFont(ofSize: size, weight: systemWeight(weight)) }
        switch face {
        case .system:
            return .systemFont(ofSize: size, weight: systemWeight(max(weight, 400)))
        case .systemMono:
            return .monospacedSystemFont(ofSize: size, weight: systemWeight(weight))
        case .variable(let postScript, let axes):
            return cached(FontKey(postScript: postScript, size: size, weight: weight)) {
                var variation: [Int: CGFloat] = axes
                variation[wghtAxis] = weight
                let d = NSFontDescriptor(name: postScript, size: size).addingAttributes([
                    NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation,
                ])
                return named(postScript, d, size) ?? fallback()
            }
        case .cuts(let cuts):
            let cut = cuts.min { abs($0.weight - weight) < abs($1.weight - weight) }!
            return cached(FontKey(postScript: cut.postScript, size: size, weight: cut.weight)) {
                named(cut.postScript, NSFontDescriptor(name: cut.postScript, size: size), size) ?? fallback()
            }
        case .named(let name):
            return cached(FontKey(postScript: "user:" + name, size: size, weight: weight)) {
                userFont(name, size, weight) ?? fallback()
            }
        }
    }

    /// A family at the nearest weight, else a PostScript name (its wght axis set when it has one);
    /// nil when neither is installed.
    private static func userFont(_ name: String, _ size: CGFloat, _ weight: CGFloat) -> NSFont? {
        let family = NSFontDescriptor(fontAttributes: [
            .family: name,
            .traits: [NSFontDescriptor.TraitKey.weight: systemWeight(weight).rawValue],
        ])
        if let font = NSFont(descriptor: family, size: size),
           font.familyName?.caseInsensitiveCompare(name) == .orderedSame {
            return font
        }
        guard let plain = NSFont(name: name, size: size), plain.fontName.caseInsensitiveCompare(name) == .orderedSame
        else { return nil }
        let axes = (CTFontCopyVariationAxes(plain as CTFont) as? [[String: Any]]) ?? []
        let hasWeightAxis = axes.contains { ($0[kCTFontVariationAxisIdentifierKey as String] as? Int) == wghtAxis }
        guard hasWeightAxis else { return plain }
        let d = plain.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        return NSFont(descriptor: d, size: size) ?? plain
    }

    /// Anything read as language. 400 regular, 500 medium, 600 semibold.
    static func sans(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        font(spec(variant).sans, size, weight, mono: false)
    }

    /// Values, labels, meta lines, keycaps.
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        font(spec(variant).mono, size, weight, mono: true)
    }

    /// The theme's display face, for titles.
    static func heading(_ size: CGFloat, _ weight: CGFloat) -> NSFont {
        font(spec(variant).heading, size, weight, mono: false)
    }

    /// DS type scale.
    /// Mono labels and meta lines, except Modern: sans, a touch larger, no shouting.
    static var label: NSFont { spec(variant).monoLabels ? mono(11, 500) : sans(12, 600) }
    static var meta: NSFont { spec(variant).monoLabels ? mono(12) : sans(12.5) }
    static var body: NSFont { sans(isModern ? 14.5 : 14) }
    static var title: NSFont { heading(18, spec(variant).titleWeight) }
    static var search: NSFont { sans(22, 300) }

    /// Micro-label: 11px mono uppercase, tracked by the theme; Modern is 12px sans as written.
    static func labelString(_ text: String, color: NSColor = mutedForeground) -> NSAttributedString {
        let s = spec(variant)
        guard s.monoLabels else {
            return NSAttributedString(string: text, attributes: [.font: label, .foregroundColor: color])
        }
        return NSAttributedString(string: text.uppercased(), attributes: [
            .font: label, .foregroundColor: color, .kern: 11 * s.tracking,
        ])
    }
}

/// A tinted status chip: earned only by states that could make you act.
struct Chip {
    enum Tone { case neutral, good, warn, bad, info }
    let text: String
    let tone: Tone

    var color: NSColor {
        switch tone {
        case .neutral: Theme.mutedForeground
        case .good: Theme.good
        case .warn: Theme.warn
        case .bad: Theme.destructive
        case .info: Theme.info
        }
    }
}

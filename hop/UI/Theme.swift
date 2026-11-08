import AppKit
import CoreText

/// hop's design system, translated to AppKit: dark-first, dense and quiet; colours
/// are tokens only; Outfit for language, Geist Mono for values and labels.
enum Theme {
    /// Set once at launch from `general.theme`; views read it while they are built.
    nonisolated(unsafe) static var variant: HopConfig.General.ThemeName = .og
    static var isModern: Bool { variant == .modern }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func pick(_ og: NSColor, _ modern: NSColor) -> NSColor { isModern ? modern : og }

    // Surfaces
    static var background: NSColor { pick(og.background, modern.background) }
    static var card: NSColor { pick(og.card, modern.card) }
    static var muted: NSColor { pick(og.muted, modern.muted) }
    static var foreground: NSColor { pick(og.foreground, modern.foreground) }
    static var mutedForeground: NSColor { pick(og.mutedForeground, modern.mutedForeground) }
    static var border: NSColor { pick(og.border, modern.border) }
    static var ring: NSColor { pick(og.ring, modern.ring) }
    static var primary: NSColor { pick(og.primary, modern.primary) }

    // Status tones: one meaning each
    static var good: NSColor { pick(og.good, modern.good) } // healthy, done
    static var warn: NSColor { pick(og.warn, modern.warn) } // needs attention
    static var info: NSColor { pick(og.info, modern.info) } // in progress, selected
    static var destructive: NSColor { pick(og.destructive, modern.destructive) } // failed, bad

    // Categorical
    static var chart1: NSColor { pick(og.chart1, modern.chart1) }
    static var chart2: NSColor { pick(og.chart2, modern.chart2) }
    static var chart3: NSColor { pick(og.chart3, modern.chart3) }
    static var chart4: NSColor { pick(og.chart4, modern.chart4) }
    static var chart5: NSColor { pick(og.chart5, modern.chart5) }

    private struct Palette {
        let background, card, muted, foreground, mutedForeground, border, ring, primary: NSColor
        let good, warn, info, destructive: NSColor
        let chart1, chart2, chart3, chart4, chart5: NSColor
    }

    /// The original: warm near-black, high contrast, green accent.
    private static let og = Palette(
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
        chart5: rgb(0.6729, 0.4741, 1.0))

    /// Modern: warm charcoal instead of black, brighter secondary text, softer tones, clay accent.
    private static let modern = Palette(
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
        chart5: rgb(0.690, 0.560, 0.940))

    static let darkAppearance = NSAppearance(named: .darkAqua)

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
        for name in ["Outfit", "GeistMono"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        fonts.removeAll() // drop fallbacks resolved before registration
    }

    private static func variable(_ postScript: String, _ size: CGFloat, _ weight: CGFloat, fallback: @autoclosure () -> NSFont) -> NSFont {
        let key = FontKey(postScript: postScript, size: size, weight: weight)
        if let cached = fonts[key] { return cached }
        let d = NSFontDescriptor(name: postScript, size: size).addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        let font = NSFont(descriptor: d, size: size)
            .flatMap { $0.fontName.lowercased().contains(postScript.prefix(4).lowercased()) ? $0 : nil } ?? fallback()
        fonts[key] = font
        return font
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

    /// Outfit (og) or SF Pro (modern): anything read as language. 400 regular, 500 medium, 600 semibold.
    static func sans(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        if isModern { return .systemFont(ofSize: size, weight: systemWeight(max(weight, 400))) }
        return variable("Outfit-Thin", size, weight, fallback: .systemFont(ofSize: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular))
    }

    /// Geist Mono (og) or SF Mono (modern): values, labels, meta lines, keycaps.
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        if isModern { return .monospacedSystemFont(ofSize: size, weight: systemWeight(weight)) }
        return variable("GeistMono-Regular", size, weight, fallback: .monospacedSystemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular))
    }

    /// DS type scale.
    /// og: mono labels and meta lines. modern: sans, a touch larger, no shouting.
    static var label: NSFont { isModern ? sans(12, 600) : mono(11, 500) }
    static var meta: NSFont { isModern ? sans(12.5) : mono(12) }
    static var body: NSFont { sans(isModern ? 14.5 : 14) }
    static var title: NSFont { sans(18, isModern ? 600 : 500) }
    static var search: NSFont { sans(22, 300) }

    /// Micro-label: og is 11px mono uppercase tracked 0.18em; modern is 12px sans as written.
    static func labelString(_ text: String, color: NSColor = mutedForeground) -> NSAttributedString {
        if isModern {
            return NSAttributedString(string: text, attributes: [.font: label, .foregroundColor: color])
        }
        return NSAttributedString(string: text.uppercased(), attributes: [
            .font: label, .foregroundColor: color, .kern: 11 * 0.18,
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

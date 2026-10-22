import AppKit
import CoreText

/// The olympus dashboard design system (olympus-dashboard/packages/ui globals.css,
/// dark theme), translated to AppKit: dark-first, dense and quiet; colours are
/// tokens only; Outfit for language, Geist Mono for values and labels.
enum Theme {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // Surfaces
    static let background = rgb(0.047, 0.047, 0.035) // #0c0c09
    static let card = rgb(0.1135, 0.1135, 0.0861)
    static let muted = rgb(0.1686, 0.1687, 0.133)
    static let foreground = rgb(0.985, 0.985, 0.976)
    static let mutedForeground = rgb(0.6706, 0.6706, 0.612)
    static let border = NSColor.white.withAlphaComponent(0.10)
    static let ring = rgb(0.486, 0.486, 0.4035)
    static let primary = rgb(0.0058, 0.4015, 0.1886)

    // Status tones: one meaning each
    static let good = rgb(0.2614, 0.8371, 0.5616) // healthy, done
    static let warn = rgb(0.989, 0.7105, 0.1729) // needs attention
    static let info = rgb(0.3348, 0.7215, 0.9707) // in progress, selected
    static let destructive = rgb(1.0, 0.3912, 0.4039) // failed, bad

    // Categorical
    static let chart1 = rgb(0.0, 0.8012, 0.5289)
    static let chart2 = rgb(1.0, 0.6865, 0.1142)
    static let chart3 = rgb(0.0, 0.688, 1.0)
    static let chart4 = rgb(1.0, 0.3469, 0.4331)
    static let chart5 = rgb(0.6729, 0.4741, 1.0)

    static let darkAppearance = NSAppearance(named: .darkAqua)

    // MARK: Fonts

    private static let wghtAxis = 0x7767_6874 // 'wght'

    static func registerFonts() {
        for name in ["Outfit", "GeistMono"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }

    private static func variable(_ postScript: String, _ size: CGFloat, _ weight: CGFloat, fallback: NSFont) -> NSFont {
        let d = NSFontDescriptor(name: postScript, size: size).addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        guard let f = NSFont(descriptor: d, size: size), f.fontName.lowercased().contains(postScript.prefix(4).lowercased()) else {
            return fallback
        }
        return f
    }

    /// Outfit: anything read as language. 400 regular, 500 medium, 600 semibold.
    static func sans(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        variable("Outfit-Thin", size, weight, fallback: .systemFont(ofSize: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular))
    }

    /// Geist Mono: values, labels, meta lines, keycaps.
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        variable("GeistMono-Regular", size, weight, fallback: .monospacedSystemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular))
    }

    /// DS type scale.
    static var label: NSFont { mono(11, 500) } // 11px mono uppercase, tracked
    static var meta: NSFont { mono(12) } // 12px meta lines
    static var body: NSFont { sans(14) } // 14px
    static var title: NSFont { sans(18, 500) } // 18px
    static var search: NSFont { sans(22, 300) }

    /// Micro-label recipe: 11px mono, uppercase, tracking 0.18em.
    static func labelString(_ text: String, color: NSColor = mutedForeground) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
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

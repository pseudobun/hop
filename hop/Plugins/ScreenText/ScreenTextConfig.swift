import Foundation

nonisolated extension HopConfig {
    nonisolated struct OCR: PluginConfig {
        static let key = "ocr"
        var enabled = true
        /// Vision recognition languages, most likely first ("en-US", "de-DE", "sl-SI").
        var languages = ["en-US"]
    }

    var ocr: OCR {
        get { sections[OCR.self] }
        set { sections[OCR.self] = newValue }
    }
}

nonisolated extension HopConfig.OCR {
    private enum Keys: String, CodingKey { case enabled, languages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self), d = Self()
        enabled = try c.value(.enabled, d.enabled)
        languages = try c.value(.languages, d.languages)
    }
}

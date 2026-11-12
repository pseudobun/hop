import AppKit
import Testing
@testable import hop

struct TranslateTests {
    let sl = Translator.Pair(["sl", "en"])

    @Test func firstLanguageGoesToSecondAndBack() {
        let en = Translator.Language("en"), slovenian = Translator.Language("sl")
        #expect(Translator.target(for: "A lahko jutri malo prej prideš? Moramo še zrihtat deploy.", pair: sl) == en)
        #expect(Translator.target(for: "Hvala za vse, se vidimo jutri", pair: sl) == en)
        #expect(Translator.target(for: "Thanks for the quick turnaround, the fix looks good.", pair: sl) == slovenian)
        #expect(sl.other(en) == slovenian && sl.other(slovenian) == en)
        let de = Translator.Pair(["de", "en"])
        #expect(Translator.target(for: "Kannst du morgen etwas früher kommen?", pair: de) == en)
        #expect(Translator.target(for: "Can you come a bit earlier tomorrow?", pair: de) == Translator.Language("de"))
    }

    @Test func pairFallbacksAndLookup() {
        #expect(Translator.Pair(["DE"]).first.code == "de" && Translator.Pair(["de"]).second.code == "en")
        #expect(Translator.Pair(["en", "en"]).first != Translator.Pair(["en", "en"]).second)
        #expect(Translator.Pair([]).first != Translator.Pair([]).second)
        #expect(sl.language(named: "slov")?.code == "sl" && sl.language(named: "EN")?.code == "en" && sl.language(named: "de") == nil)
        #expect(Translator.Language("sl").name == "Slovenian")
    }

    @Test func instructionsNameTheTarget() {
        #expect(Translator.instructions(Translator.Language("en"), pair: sl).contains("into English"))
        #expect(Translator.instructions(Translator.Language("sl"), pair: sl).contains("between Slovenian and English"))
    }

    @Test func configDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let config = try decoder.decode(HopConfig.self, from: Data("{translate: {model: 'gpt-6.1-sol', languages: ['sl', 'en']}, ocr: {enabled: false, languages: ['sl-SI', 'en-US']}}".utf8))
        #expect(config.translate.model == "gpt-6.1-sol" && config.translate.reasoning == "none" && !config.ocr.enabled)
        #expect(config.translate.languages == ["sl", "en"] && config.ocr.languages == ["sl-SI", "en-US"])
        #expect(HopConfig.Translate().languages.isEmpty && HopConfig.OCR().languages == ["en-US"])
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.translate == HopConfig.Translate() && template.ocr == HopConfig.OCR())
    }
}

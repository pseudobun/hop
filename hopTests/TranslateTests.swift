import AppKit
import Testing
@testable import hop

struct TranslateTests {
    @Test func slovenianGoesToEnglishAndBack() {
        #expect(Translator.target(for: "A lahko jutri malo prej prideš? Moramo še zrihtat deploy.") == .english)
        #expect(Translator.target(for: "Hvala za vse, se vidimo jutri") == .english)
        #expect(Translator.target(for: "Thanks for the quick turnaround, the fix looks good.") == .slovenian)
        #expect(Translator.Language.english.other == .slovenian)
    }

    @Test func instructionsNameTheTarget() {
        #expect(Translator.instructions(.english).contains("into English"))
        #expect(Translator.instructions(.slovenian).contains("into Slovenian"))
    }

    @Test func configDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let config = try decoder.decode(HopConfig.self, from: Data("{translate: {model: 'gpt-6.1-sol'}, ocr: {enabled: false}}".utf8))
        #expect(config.translate.model == "gpt-6.1-sol" && config.translate.reasoning == "none" && !config.ocr.enabled)
        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.translate == HopConfig.Translate() && template.ocr == HopConfig.OCR())
    }

    @Test func readsTextFromAnImage() async throws {
        let size = NSSize(width: 900, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
            ("Dober dan, svet" as NSString).draw(at: NSPoint(x: 30, y: 110), withAttributes: attrs)
            ("Hello from hop OCR" as NSString).draw(at: NSPoint(x: 30, y: 30), withAttributes: attrs)
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appending(path: "hop-ocr-test-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = await ScreenText.recognize(url)
        #expect(lines == ["Dober dan, svet", "Hello from hop OCR"])
    }
}

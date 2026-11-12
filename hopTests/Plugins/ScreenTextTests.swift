import AppKit
import Testing
@testable import hop

struct ScreenTextTests {
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
        let lines = await ScreenText.recognize(url, languages: ["sl-SI", "en-US"])
        #expect(lines == ["Dober dan, svet", "Hello from hop OCR"])
    }
}

@MainActor
struct ScreenTextPluginTests {
    @Test func configDefaultsAndSwitch() throws {
        #expect(HopConfig().ocr.enabled && HopConfig().ocr.languages == ["en-US"])
        let info = ScreenTextPlugin.info
        #expect(info.id == "ocr" && info.enabledPath == ["ocr", "enabled"] && info.isEnabled(in: HopConfig()))
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let off = try d.decode(HopConfig.self, from: Data("{ ocr: { enabled: false, languages: [\"sl-SI\"] } }".utf8))
        #expect(!info.isEnabled(in: off) && off.ocr.languages == ["sl-SI"])
    }

    @Test func commandFollowsTheSwitch() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try "{ ocr: { enabled: false } }".write(to: url, atomically: true, encoding: .utf8)
        let off = Services(settings: AppSettings(url: url), frecency: FrecencyStore(store: JSONStore(url: dir.appending(path: "f.json"))), apps: AppIndex())
        #expect(ScreenTextCommands.items(off).isEmpty)
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        let on = Services(settings: AppSettings(url: url), frecency: FrecencyStore(store: JSONStore(url: dir.appending(path: "f.json"))), apps: AppIndex())
        #expect(ScreenTextCommands.items(on).map(\.id) == ["ocr.copy"])
        #expect(ScreenTextPlugin.cli.map(\.names) == [["ocr"]])
    }
}

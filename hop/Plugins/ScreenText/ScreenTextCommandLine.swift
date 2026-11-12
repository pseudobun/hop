import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the ScreenText plugin.
extension ScreenTextPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["ocr"], usage: [
                "ocr [image] [--copy] [--json]       Text in an image, or in an area you select on screen",
            ], run: CLI.ocr),
        ]
    }
}

extension CLI {
    /// `hop ocr [image] [--copy]`: text in an image, or in an area you select on screen.
    static func ocr(_ a: Args) async -> Int32 {
        var url: URL
        var temporary = false
        if let path = a.positional.first {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return Output.fail("no such file: \(path)") }
        } else {
            guard let captured = await ScreenText.capture() else { return Output.fail("no area selected") }
            url = captured
            temporary = true
        }
        defer { if temporary { try? FileManager.default.removeItem(at: url) } }
        let lines = await ScreenText.recognize(url, languages: AppSettings().data.ocr.languages)
        guard !lines.isEmpty else { return Output.fail("no text found") }
        let text = lines.joined(separator: "\n")
        if a.flags.contains("copy") { Pasteboard.copy(text) }
        if a.json { Output.json(["lines": lines, "text": text]) } else { print(text) }
        return 0
    }
}

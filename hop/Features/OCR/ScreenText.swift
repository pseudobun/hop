import AppKit
import Vision

/// Text from a part of the screen: pick a region with macOS's own selection (screencapture
/// -i, Esc cancels), read it with Vision on this Mac, put the text on the clipboard.
nonisolated enum ScreenText {
    private static let queue = DispatchQueue(label: "hop.ocr", qos: .userInitiated)

    /// The selected region as a PNG, or nil when the selection was cancelled.
    static func capture() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "hop-ocr-\(UUID().uuidString).png")
        _ = try? await ProcessRunner.run("/usr/sbin/screencapture", ["-i", "-x", url.path], timeout: .seconds(120))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Lines in reading order, in the `ocr.languages`, with language correction.
    static func recognize(_ url: URL, languages: [String]) async -> [String] {
        await withCheckedContinuation { done in
            queue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages
                let handler = VNImageRequestHandler(url: url)
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                done.resume(returning: lines)
            }
        }
    }

    /// Capture, read and copy; the HUD says how it went.
    static func copyFromScreen(languages: [String]) async {
        guard let url = await capture() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = await recognize(url, languages: languages)
        guard !lines.isEmpty else {
            await HUD.shared.warn("No text found in that part of the screen")
            return
        }
        let text = lines.joined(separator: "\n")
        await Pasteboard.copy(text)
        await HUD.shared.show(lines.count == 1 ? "Copied “\(text.prefix(40))”" : "Copied \(lines.count) lines of text")
    }
}

/// Root command.
enum ScreenTextCommands {
    static func items(_ services: Services) -> [Item] {
        guard services.settings.data.ocr.enabled else { return [] }
        return [
            Item(id: "ocr.copy", title: "Copy Text from Screen", subtitle: "Select an area; its text goes to the clipboard",
                 aliases: ["ocr", "screen text", "text from image"],
                 icon: .tile("text.viewfinder", Palette.ocr), accessory: "Command",
                 actions: [Action(title: "Select Area", symbol: "text.viewfinder") {
                     services.hideLauncher?()
                     await ScreenText.copyFromScreen(languages: services.settings.data.ocr.languages)
                     return .stay
                 }]),
        ]
    }
}

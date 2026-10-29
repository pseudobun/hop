import AppKit

/// Opens the config in the app that opens .json5 files, at a line when that editor can
/// jump to one: a URL scheme for VS Code and its forks, the bundled CLI for Zed and Sublime.
nonisolated enum ConfigOpener {
    enum Launch: Equatable {
        case url(URL)
        case command(String, [String])
        case plain
    }

    /// How to open `file` at `line` in the editor with `bundleID`, installed at `app`.
    static func launch(bundleID: String?, app: URL?, file: URL, line: Int?, column: Int?) -> Launch {
        guard let line, let bundleID else { return .plain }
        let column = column ?? 1
        let path = file.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        func scheme(_ name: String) -> Launch {
            URL(string: "\(name)://file\(encoded):\(line):\(column)").map(Launch.url) ?? .plain
        }
        func tool(_ relative: String) -> String? { app.map { $0.appending(path: relative).path } }

        switch bundleID {
        case "com.microsoft.VSCode": return scheme("vscode")
        case "com.microsoft.VSCodeInsiders": return scheme("vscode-insiders")
        case "com.todesktop.230313mzl4w4u92": return scheme("cursor")
        case "com.exafunction.windsurf": return scheme("windsurf")
        case "dev.zed.Zed", "dev.zed.Zed-Preview":
            if let cli = tool("Contents/MacOS/cli") { return .command(cli, ["\(path):\(line):\(column)"]) }
            return scheme("zed")
        case let id where id.hasPrefix("com.sublimetext."):
            guard let subl = tool("Contents/SharedSupport/bin/subl") else { return .plain }
            return .command(subl, ["\(path):\(line):\(column)"])
        case "com.macromates.TextMate":
            let fileURL = file.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "="]))
            return fileURL.flatMap { URL(string: "txmt://open?url=\($0)&line=\(line)&column=\(column)") }.map(Launch.url) ?? .plain
        default: return .plain
        }
    }

    /// Opens `file`, at the issue's line when there is one; anything that fails falls back to a plain open.
    @MainActor static func open(_ file: URL, at issue: ConfigIssue? = nil) {
        let app = NSWorkspace.shared.urlForApplication(toOpen: file)
        let bundleID = app.flatMap { Bundle(url: $0)?.bundleIdentifier }
        switch launch(bundleID: bundleID, app: app, file: file, line: issue?.line, column: issue?.column) {
        case .url(let url):
            if !NSWorkspace.shared.open(url) { openPlain(file) }
        case .command(let tool, let arguments):
            guard FileManager.default.isExecutableFile(atPath: tool),
                  (try? Process.run(URL(fileURLWithPath: tool), arguments: arguments)) != nil
            else { return openPlain(file) }
        case .plain:
            openPlain(file)
        }
    }

    /// The default app, or TextEdit when nothing claims .json5.
    @MainActor static func openPlain(_ file: URL) {
        if NSWorkspace.shared.urlForApplication(toOpen: file) != nil {
            NSWorkspace.shared.open(file)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

import AppKit
import EventKit

/// CLI commands for the newer features: Messages codes, Calendar, translation, OCR,
/// emoji, bookmarks and permissions. Same conventions: tab-separated text, `--json`.
extension CLI {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()







    /// `hop permissions [--json]`: what hop has been granted, as the Permissions screen shows it.
    static func permissions(_ a: Args) async -> Int32 {
        let rows = Permission.allCases.map { p -> (String, String, Bool) in
            let status = switch p.status() {
            case .granted: "granted"
            case .missing: "missing"
            case .unknown: "not asked"
            }
            return (p.title, status, p.isOptional)
        }
        if a.json {
            Output.json(rows.map { ["permission": $0.0, "status": $0.1, "optional": $0.2] })
        } else {
            for r in rows { print("\(r.0)\t\(r.1)\(r.2 ? " (optional)" : "")") }
        }
        return 0
    }


    static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isNewline).joined(separator: " ") }

    static func stdinInput() -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
}

import Foundation

/// Golden fixtures from ~/repos/raycast-re, read from the source tree.
nonisolated enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func json(_ name: String) -> [String: Any] {
        let data = try! Data(contentsOf: directory.appending(path: name))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func text(_ name: String) -> String {
        try! String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    static var search: [String: Any] { json("search_golden.json") }
    static var frecency: [String: Any] { json("frecency_golden.json") }
}

import Foundation
import os

/// Small Codable file in Application Support, written atomically.
nonisolated struct JSONStore<Value: Codable>: Sendable {
    let url: URL
    var protected = false

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            if protected {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            Log.app.error("JSONStore save failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

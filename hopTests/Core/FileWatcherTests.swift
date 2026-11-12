import Foundation
import Testing
@testable import hop

struct FileWatcherTests {
    /// In-place writes (VS Code, scripts) only change the file; replacing it (vim, `sed -i`)
    /// only shows on the folder, and later in-place writes hit the new file.
    @Test func seesInPlaceWritesAndReplacements() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try Data("1".utf8).write(to: url)

        var changes = 0
        let watcher = FileWatcher(url: url) { changes += 1 }
        defer { watcher.stop() }
        func wait(for n: Int) async {
            for _ in 0..<60 where changes < n { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func writeInPlace(_ text: String) throws {
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: Data(text.utf8))
            try h.close()
        }

        try writeInPlace("2")
        await wait(for: 1)
        #expect(changes == 1)

        try Data("3".utf8).write(to: url, options: .atomic)
        await wait(for: 2)
        #expect(changes == 2)

        try writeInPlace("4")
        await wait(for: 3)
        #expect(changes == 3)
    }
}

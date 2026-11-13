import Foundation
import Testing
@testable import hop

/// Config saves that must reach the running hop without a restart.
struct ConfigLiveReloadTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A broken save keeps the config, so only the error changes: the launcher and Settings still
    /// hear about it, and about the fix.
    @Test func errorsAndWarningsReportWithoutAConfigChange() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try "{ general: { keepQueryFor: 5 } }".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(url: url)
        var changes = 0, statuses = 0
        settings.onChange = { _, _ in changes += 1 }
        settings.onStatusChange = { statuses += 1 }

        try "{ general: { keepQueryFor: 5 ".write(to: url, atomically: true, encoding: .utf8)
        settings.load()
        #expect(settings.error != nil && settings.data.general.keepQueryFor == 5)
        #expect(changes == 0 && statuses == 1)

        try "{ general: { keepQueryFor: 5 } }".write(to: url, atomically: true, encoding: .utf8)
        settings.load()
        #expect(settings.error == nil && changes == 0 && statuses == 2)

        try "{ general: { keepQueryFor: 5, hotkeyy: \"x\" } }".write(to: url, atomically: true, encoding: .utf8)
        settings.load()
        #expect(settings.warnings.count == 1 && changes == 0 && statuses == 3)

        // Nothing new: quiet.
        settings.load()
        #expect(changes == 0 && statuses == 3)
    }

    /// A config gone for a moment (replaced by an editor or a sync) does not reset everything.
    @Test func missingFileKeepsTheLastConfig() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json5")
        try "{ general: { keepQueryFor: 5 } }".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(url: url)
        var changes = 0
        settings.onChange = { _, _ in changes += 1 }
        try FileManager.default.removeItem(at: url)
        settings.load()
        #expect(settings.data.general.keepQueryFor == 5 && changes == 0)
        // Fresh, without a file: the defaults.
        #expect(AppSettings(url: dir.appending(path: "none.json5")).data == HopConfig())
    }

    /// `.env` is watched where it really lives (a symlink into dotfiles), so a new value applies.
    @Test func envChangesReload() async throws {
        let dir = try folder(), dotfiles = try folder()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: dotfiles)
        }
        let url = dir.appending(path: "config.json5")
        try "{ notes: { folder: \"${HOP_TEST_NOTES}\" } }".write(to: url, atomically: true, encoding: .utf8)
        let env = dotfiles.appending(path: ".env")
        try "HOP_TEST_NOTES=/a\n".write(to: env, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: ".env"), withDestinationURL: env)
        #expect(ConfigEnv.file(beside: url).resolvingSymlinksInPath().path == env.resolvingSymlinksInPath().path)

        let settings = AppSettings(url: url)
        settings.start()
        #expect(settings.data.notes.folder == "/a")
        // In place, as an editor following the symlink writes it.
        let h = try FileHandle(forWritingTo: env)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data("HOP_TEST_NOTES=/b\n".utf8))
        try h.close()
        for _ in 0..<60 where settings.data.notes.folder != "/b" { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(settings.data.notes.folder == "/b")
    }
}

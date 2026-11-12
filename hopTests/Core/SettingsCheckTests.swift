import Foundation
import Testing
@testable import hop

@MainActor
struct SettingsCheckTests {
    @Test func foldersFilesAndPrograms() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "f.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(SettingsChecks.folder()(dir.path) == nil)
        #expect(SettingsChecks.folder()(dir.path + "/nope")?.level == .warning)
        #expect(SettingsChecks.folder()(file.path)?.level == .error)
        #expect(SettingsChecks.folder()("")?.level == .error && SettingsChecks.folder(optional: true)("") == nil)
        #expect(SettingsChecks.file(file.path) == nil && SettingsChecks.file(dir.path)?.level == .error)
        #expect(SettingsChecks.executable("") == nil && SettingsChecks.executable("/bin/sh") == nil)
        #expect(SettingsChecks.executable(file.path)?.level == .error)
        #expect(SettingsChecks.folders([dir.path, "/nope"])?.level == .warning)
    }

    @Test func codesAndNames() {
        #expect(SettingsChecks.languagePair([String]()) == nil && SettingsChecks.languagePair(["sl", "en"]) == nil)
        #expect(SettingsChecks.languagePair(["sl"])?.level == .error)
        #expect(SettingsChecks.languagePair(["sl", "xx"])?.level == .error)
        #expect(SettingsChecks.languagePair(["en", "EN"])?.level == .error)
        #expect(SettingsChecks.currency("eur") == nil && SettingsChecks.currency("ZZZ")?.level == .error)
        #expect(SettingsChecks.modifiers("") == nil && SettingsChecks.modifiers("ctrl+alt") == nil)
        #expect(SettingsChecks.modifiers("shift+meta")?.level == .error)
        #expect(SettingsChecks.fallbacks(["google", "https://x.dev/?q={query}"]) == nil)
        #expect(SettingsChecks.fallbacks(["bing"])?.level == .error)
        #expect(SettingsChecks.relativeFolder("Inbox/2026") == nil && SettingsChecks.relativeFolder("../x")?.level == .error)
        #expect(SettingsChecks.bundleIDs(["bad id"])?.level == .error)
        #expect(SettingsChecks.bundleIDs(["com.example.notinstalled"])?.level == .warning)
        #expect(SettingsChecks.required("") != nil && SettingsChecks.required("x") == nil)
    }

    @Test func fieldsCarryTheirChecks() {
        for key in ["notes.folder", "calculator.currency", "translate.languages", "clipboard.ignoreApps", "general.fallbacks", "ocr.languages"] {
            #expect(SettingsCatalog.field(at: key.split(separator: ".").map(String.init))?.check != nil, "\(key)")
        }
        var config = HopConfig()
        config.calculator.currency = "ZZZ"
        #expect(SettingsCatalog.problems(in: config).contains { $0.key == "calculator.currency" && $0.problem.level == .error })
    }
}

import AppKit
import Foundation
import Testing
@testable import hop

@MainActor
struct CustomThemeTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func parsesHexColours() throws {
        let c = try #require(CustomThemes.color(hex: "#2e3440"))
        #expect(CustomThemes.hex(c) == "#2e3440")
        #expect(CustomThemes.hex(try #require(CustomThemes.color(hex: "fff"))) == "#ffffff")
        #expect(CustomThemes.hex(try #require(CustomThemes.color(hex: "#00000080"))) == "#00000080")
        #expect(CustomThemes.color(hex: "#12345") == nil)
        #expect(CustomThemes.color(hex: "tomato") == nil)
    }

    @Test func fileOverridesItsBase() throws {
        let file = try CustomThemes.decode(Data("""
        { name: "Nord", base: "og-light", light: false,
          colors: { background: "#2e3440", primary: "#88c0d0", bogus: "#fff", foreground: "nope" },
          fonts: { sans: "Helvetica Neue", mono: "system-mono" }, monoLabels: false, titleWeight: 2000 }
        """.utf8))
        let (spec, issues) = CustomThemes.spec(from: file, id: "nord")
        let base = try #require(Theme.builtIn(.ogLight))
        #expect(spec.label == "Nord")
        #expect(!spec.light)
        #expect(spec.base == .ogLight)
        #expect(CustomThemes.hex(spec.palette.background) == "#2e3440")
        #expect(CustomThemes.hex(spec.palette.primary) == "#88c0d0")
        #expect(CustomThemes.hex(spec.palette.foreground) == CustomThemes.hex(base.palette.foreground))
        #expect(CustomThemes.hex(spec.palette.card) == CustomThemes.hex(base.palette.card))
        #expect(!spec.monoLabels)
        #expect(spec.titleWeight == 900)
        #expect(spec.tracking == base.tracking)
        guard case .named("Helvetica Neue") = spec.sans, case .systemMono = spec.mono else {
            Issue.record("fonts not read")
            return
        }
        #expect(issues.count == 2)
        #expect(issues.contains { $0.contains("bogus") })
        #expect(issues.contains { $0.contains("colors.foreground") })
    }

    @Test func unknownBaseFallsBackToOG() throws {
        let (spec, issues) = CustomThemes.spec(from: ThemeFile(base: "nord"), id: "x")
        #expect(spec.base == .og)
        #expect(spec.label == "x")
        #expect(issues.count == 1)
    }

    @Test func loadsAFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{ name: \"Zed\" }".write(to: dir.appending(path: "zed.json5"), atomically: true, encoding: .utf8)
        try "{ name: \"Alpha\", colors: { primary: \"#f00\" } }".write(to: dir.appending(path: "alpha.json"), atomically: true, encoding: .utf8)
        try "{ name: ".write(to: dir.appending(path: "broken.json5"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appending(path: "og.json5"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let loaded = CustomThemes.load(from: dir)
        #expect(loaded.themes.map(\.name.rawValue) == ["alpha", "zed"])
        #expect(loaded.issues.count == 2)
        #expect(loaded.issues.contains { $0.hasPrefix("broken.json5") })
        #expect(loaded.issues.contains { $0.hasPrefix("og.json5") })
        #expect(CustomThemes.load(from: dir.appending(path: "missing")).themes.isEmpty)
    }

    @Test func registersAndSelectsCustomThemes() throws {
        defer {
            Theme.setCustom([])
            Theme.variant = .og
        }
        let (spec, _) = CustomThemes.spec(from: ThemeFile(name: "Mine", colors: ["primary": "#123456"]), id: "mine")
        Theme.setCustom([("mine", spec)])
        #expect(Theme.exists("mine"))
        #expect(Theme.all.last == "mine")
        Theme.variant = "mine"
        #expect(CustomThemes.hex(Theme.primary) == "#123456")
    }

    @Test func templateRoundTrips() throws {
        let og = try #require(Theme.builtIn(.og))
        let file = try CustomThemes.decode(Data(CustomThemes.defaultTemplate.utf8))
        let (spec, issues) = CustomThemes.spec(from: file, id: "my-theme")
        #expect(issues.isEmpty)
        #expect(spec.label == "My Theme")
        for key in Theme.Palette.keys {
            #expect(CustomThemes.hex(spec.palette[key]!) == CustomThemes.hex(og.palette[key]!), "\(key)")
        }
        #expect(spec.monoLabels == og.monoLabels && spec.tracking == og.tracking && spec.titleWeight == og.titleWeight)
    }

    @Test func createsAndImports() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try CustomThemes.create(in: dir, from: .cyberpunk)
        let second = try CustomThemes.create(in: dir, from: .cyberpunk)
        #expect(first.lastPathComponent == "my-cyberpunk.json5")
        #expect(second.lastPathComponent == "my-cyberpunk-2.json5")

        let source = try folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let good = source.appending(path: "My Nord.json5")
        try "{ name: \"Nord\" }".write(to: good, atomically: true, encoding: .utf8)
        #expect(try CustomThemes.importFiles([good], into: dir) == ["my-nord"])
        let bad = source.appending(path: "bad.json5")
        try "{".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: CustomThemes.ImportError.self) { try CustomThemes.importFiles([bad], into: dir) }
        #expect(CustomThemes.load(from: dir).themes.count == 3)
    }
}

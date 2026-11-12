import AppKit
import Foundation
import Testing
@testable import hop

struct ConfigEditTests {
    @Test func replacesExistingTheme() {
        let text = "{\n  general: {\n    // \"og\" or \"modern\"\n    theme: \"og\",\n    menuBarIcon: true,\n  },\n}\n"
        #expect(ConfigEdit.settingTheme(in: text, to: "cyberpunk")
            == "{\n  general: {\n    // \"og\" or \"modern\"\n    theme: \"cyberpunk\",\n    menuBarIcon: true,\n  },\n}\n")
    }

    @Test func ignoresCommentedTheme() {
        let text = "{\n  general: {\n    // theme: \"og\",\n    menuBarIcon: true,\n  },\n}\n"
        #expect(ConfigEdit.settingTheme(in: text, to: "solarpunk")
            == "{\n  general: {\n    theme: \"solarpunk\",\n    // theme: \"og\",\n    menuBarIcon: true,\n  },\n}\n")
    }

    @Test func addsGeneralWhenMissing() {
        #expect(ConfigEdit.settingTheme(in: "{\n}\n", to: "og-light") == "{\n  general: { theme: \"og-light\" },\n}\n")
        #expect(ConfigEdit.settingTheme(in: "", to: "og") == nil)
    }

    @Test func everyThemeDecodes() throws {
        for name in HopConfig.General.ThemeName.builtIn {
            let d = JSONDecoder()
            d.allowsJSON5 = true
            let c = try d.decode(HopConfig.self, from: Data("{ general: { theme: \"\(name.rawValue)\" } }".utf8))
            #expect(c.general.theme == name)
        }
    }

    @Test func bundledFontsResolve() {
        Theme.registerFonts()
        defer { Theme.variant = .og }
        let expected: [HopConfig.General.ThemeName: (String, String, String)] = [
            .og: ("outfit", "geist", "outfit"),
            .solarpunk: ("nunito", "dmmono", "fraunces"),
            .cyberpunk: ("chakra", "sharetech", "orbitron"),
        ]
        for (name, fonts) in expected {
            Theme.variant = name
            #expect(Theme.body.fontName.lowercased().contains(fonts.0))
            #expect(Theme.label.fontName.lowercased().contains(fonts.1))
            #expect(Theme.title.fontName.lowercased().contains(fonts.2))
        }
    }

    @Test func unknownThemeDecodesAndFallsBackToOG() throws {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let c = try d.decode(HopConfig.self, from: Data("{ general: { theme: \"nord\" } }".utf8))
        #expect(c.general.theme.rawValue == "nord")
        #expect(!Theme.exists(c.general.theme))
        #expect(Theme.spec(c.general.theme).label == "OG")
        #expect(ConfigDiagnostics.warnings(in: "{ general: { theme: \"nord\" } }").isEmpty)
    }
}

import Foundation
import Testing
@testable import hop

struct LeftoverScannerTests {
    @Test func findsLeftoversByBundleIDAndGroup() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hop-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let make: (String) throws -> Void = { rel in
            let url = home.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rel.hasSuffix("/") { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            else { try Data().write(to: url) }
        }
        try make("Library/Application Support/com.acme.app/")
        try make("Library/Caches/com.acme.app/")
        try make("Library/Preferences/com.acme.app.plist")
        try make("Library/Preferences/com.acme.app.helper.plist")
        try make("Library/Saved Application State/com.acme.app.savedState/")
        try make("Library/Group Containers/TEAM123.com.acme.shared/")
        try make("Library/HTTPStorages/com.acme.app.binarycookies")
        // Must not match
        try make("Library/Preferences/com.acme.application.plist")
        try make("Library/Application Support/com.acme.other/")
        try make("Library/Caches/com.acmeapp/")

        let found = LeftoverScanner.scan(bundleID: "com.acme.app", groups: ["TEAM123.com.acme.shared"], home: home)
            .map { $0.path.replacingOccurrences(of: home.path + "/", with: "") }
        #expect(found == [
            "Library/Application Support/com.acme.app",
            "Library/Caches/com.acme.app",
            "Library/Group Containers/TEAM123.com.acme.shared",
            "Library/HTTPStorages/com.acme.app.binarycookies",
            "Library/Preferences/com.acme.app.helper.plist",
            "Library/Preferences/com.acme.app.plist",
            "Library/Saved Application State/com.acme.app.savedState",
        ])
    }

    @Test func systemAppsAreNotRemovable() {
        #expect(!UninstallMode.isRemovable("/System/Applications/Mail.app"))
        #expect(UninstallMode.isRemovable("/Applications/Slack.app"))
    }
}

struct ConfigTests {
    static func decode(_ text: String) throws -> HopConfig {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        return try d.decode(HopConfig.self, from: Data(text.utf8))
    }

    @Test func templateParsesToDefaults() throws {
        var expected = HopConfig()
        expected.keepass.database = "~/Documents/Passwords.kdbx"
        #expect(try Self.decode(AppSettings.template) == expected)
    }

    @Test func partialConfigKeepsDefaults() throws {
        let c = try Self.decode("""
        // comment
        { keepass: { enabled: true, database: "~/k.kdbx", password: "command", passwordCommand: "pass x", }, }
        """)
        #expect(c.keepass.enabled)
        #expect(c.keepass.password == .command)
        #expect(c.keepass.lockAfterMinutes == 10)
        #expect(c.general.hotkey == "cmd+space")
        #expect(c.general.sensitivity == .high)
    }

    @Test func invalidValuesThrow() {
        #expect(throws: (any Error).self) { try Self.decode(#"{ general: { sensitivity: "extreme" } }"#) }
        #expect(throws: (any Error).self) { try Self.decode(#"{ general: { "#) }
    }

    @Test func emptyFileGivesDefaults() throws {
        #expect(try Self.decode("{}") == HopConfig())
    }
}

struct HotkeySpecTests {
    @Test func parses() {
        #expect(HotkeySpec.parse("cmd+space") == HotkeySpec(keyCode: 49, modifiers: 256))
        #expect(HotkeySpec.parse("Alt + Space") == HotkeySpec(keyCode: 49, modifiers: 2048))
        #expect(HotkeySpec.parse("hyper+k")?.modifiers == 256 | 512 | 2048 | 4096)
        #expect(HotkeySpec.parse("f13") != nil)
        #expect(HotkeySpec.parse("space") == nil)
        #expect(HotkeySpec.parse("cmd+nope") == nil)
        #expect(HotkeySpec.parse("meta+space") == nil)
    }
}

struct HyperKeyMappingTests {
    @Test func parsesHidutilOutput() {
        let text = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771183;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771300;
                HIDKeyboardModifierMappingSrc = 30064771301;
            }
        )
        """
        let entries = HyperKeyMapping.parse(text)
        #expect(entries.count == 2)
        #expect(entries[0]["HIDKeyboardModifierMappingSrc"] == HyperKeyMapping.capsLock)
        #expect(entries[0]["HIDKeyboardModifierMappingDst"] == HyperKeyMapping.f20)
        #expect(HyperKeyMapping.parse("(null)").isEmpty)
        #expect(HyperKeyMapping.json(entries).contains("\"HIDKeyboardModifierMappingSrc\":30064771129"))
    }
}

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

    @Test func findsHelperIDsAppNameAndSystemLeftovers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hop-uninstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let make: (String) throws -> Void = { rel in
            let url = root.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rel.hasSuffix("/") { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            else { try Data().write(to: url) }
        }
        let plist = { (id: String) in
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>\(id)</string></dict></plist>"
        }
        let app = root.appending(path: "Apps/Acme.app")
        try make("Apps/Acme.app/Contents/Library/LoginItems/Acme Launcher.app/Contents/")
        try plist("com.acme.app").write(to: app.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        try plist("de.acme.launcher").write(to: app.appending(path: "Contents/Library/LoginItems/Acme Launcher.app/Contents/Info.plist"),
                                            atomically: true, encoding: .utf8)
        try make("Apps/Acme.app/Contents/Library/LaunchServices/de.acme.privileged")
        #expect(LeftoverScanner.bundleIDs(of: app) == ["com.acme.app", "de.acme.launcher", "de.acme.privileged"])

        try make("home/Library/Containers/de.acme.launcher/")
        try make("home/Library/Application Scripts/com.acme.app/")
        try make("home/Library/Preferences/ByHost/com.acme.app.0123-4567.plist")
        try make("home/Library/Application Support/Acme/")
        try make("system/Library/LaunchDaemons/de.acme.privileged.plist")
        try make("system/Library/PrivilegedHelperTools/de.acme.privileged")
        // Must not match: the name only counts in Application Support, Caches and Logs.
        try make("home/Library/Preferences/Acme/")
        try make("home/Library/Application Support/Acme Other/")

        let found = LeftoverScanner.scan(bundleIDs: LeftoverScanner.bundleIDs(of: app), appName: "Acme",
                                         home: root.appending(path: "home"), systemRoot: root.appending(path: "system"))
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(found == [
            "home/Library/Application Scripts/com.acme.app",
            "home/Library/Application Support/Acme",
            "home/Library/Containers/de.acme.launcher",
            "home/Library/Preferences/ByHost/com.acme.app.0123-4567.plist",
            "system/Library/LaunchDaemons/de.acme.privileged.plist",
            "system/Library/PrivilegedHelperTools/de.acme.privileged",
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
        expected.keepass.databases = [.init(name: "Personal", path: "~/Passwords.kdbx")]
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

    @Test func legacySingleDatabase() throws {
        let c = try Self.decode(#"{ keepass: { database: "~/a.kdbx", password: "none" } }"#)
        #expect(c.keepass.allDatabases == [.init(name: "", path: "~/a.kdbx", password: .none)])
        #expect(c.keepass.allDatabases[0].label == "a")
        let multi = try Self.decode(#"{ keepass: { database: "~/ignored.kdbx", databases: [{ name: "W", path: "~/w.kdbx" }, { path: "" }] } }"#)
        #expect(multi.keepass.allDatabases.map(\.label) == ["W"])
    }

    @Test func emptyFileGivesDefaults() throws {
        #expect(try Self.decode("{}") == HopConfig())
    }
}

struct HotkeySpecTests {
    @Test func parses() {
        #expect(HotkeySpec.parse("cmd+space") == HotkeySpec(keyCode: 49, modifiers: 256))
        #expect(HotkeySpec.parse("Alt + Space") == HotkeySpec(keyCode: 49, modifiers: 2048))
        let hyper = UInt32(256 | 512 | 2048 | 4096) // ⌘ ⇧ ⌥ ⌃
        #expect(HotkeySpec.parse("hyper+k")?.modifiers == hyper)
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

struct ProcessesTests {
    @Test func parsesPs() {
        let out = """
          0     0   0,0      0 kernel_task
          1     0   0.1  12000 /sbin/launchd
        512   501  12.5 204800 /Applications/Safari.app/Contents/MacOS/Safari
        733   501   0.0   1024 /usr/libexec/some helper
        999   501   3.0   4096 /bin/zsh
        """
        let p = Processes.parse(out, excluding: [999])
        #expect(p.map(\.pid) == [512, 733])
        #expect(p[0].name == "Safari" && p[0].memory == 204_800 * 1024 && p[0].cpu == 12.5)
        #expect(p[1].path == "/usr/libexec/some helper")
    }

    @Test func paneNames() {
        #expect(AppScanner.prettifyPaneName("KeyboardSettings") == "Keyboard")
        // Only changes that can change the app list rescan it.
        #expect(AppScanner.affectsIndex("/Applications/"))
        #expect(AppScanner.affectsIndex("/Applications/Utilities/"))
        #expect(AppScanner.affectsIndex("/Applications/Foo.app/"))
        #expect(AppScanner.affectsIndex("/Applications/Foo.app/Contents/"))
        #expect(!AppScanner.affectsIndex("/Applications/Foo.app/Contents/Frameworks/Bar.framework/"))
        #expect(!AppScanner.affectsIndex("/Applications/Foo.app/Contents/Resources/"))
        #expect(AppScanner.prettifyPaneName("ControlCenterSettings") == "Control Center")
        #expect(AppScanner.prettifyPaneName("Date & Time") == "Date & Time")
        #expect(AppScanner.prettifyPaneName("Bluetooth") == "Bluetooth")
    }
}

struct ConfigEditorTests {
    @Test func flipsOnlyTheKey() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hop-config-\(UUID().uuidString).json5")
        defer { try? FileManager.default.removeItem(at: url); unsetenv("HOP_CONFIG") }
        try AppSettings.template.replacingOccurrences(of: "openAtLogin: true", with: "openAtLogin: false")
            .write(to: url, atomically: true, encoding: .utf8)
        setenv("HOP_CONFIG", url.path, 1)
        #expect(ConfigEditor.setBool("openAtLogin", true))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("openAtLogin: true,"))
        #expect(text.contains("// hop configuration"))
        #expect(text.contains("menuBarIcon: true"))
        #expect(!ConfigEditor.setBool("doesNotExist", true))
    }
}

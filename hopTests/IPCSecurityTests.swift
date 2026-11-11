import Foundation
import Testing
@testable import hop

struct IPCSecurityTests {
    private func rings(_ json5: String) throws -> [HopConfig.Ring] {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        return try d.decode(HopConfig.self, from: Data(json5.utf8)).rings.rings
    }

    @Test func cliRunsOnlyConfiguredCodeActions() throws {
        let configured = try rings("""
        { rings: { rings: [{ name: "Dev", slices: [
            { action: "shell:say hi" },
            { title: "More", children: [{ action: "type:hello\\\\n" }] },
        ] }] } }
        """)
        let allowed = { (text: String) in RingController.allowsFromCLI(RingActionRef.parse(text)!, rings: configured) }
        #expect(allowed("shell:say hi"))
        #expect(allowed("type:hello\\n"))
        #expect(!allowed("shell:touch ~/pwned"))
        #expect(!allowed("applescript:do shell script \"id\""))
        #expect(!allowed("type:rm -rf ~/x\\n"))
        #expect(!allowed("key:cmd+q"))
        #expect(!allowed("menu:File > Quit"))
        #expect(!allowed("url:x-apple.systempreferences:"))
        #expect(!allowed("shortcut:Anything"))
        #expect(allowed("app:Finder"))
        #expect(allowed("folder:~/Downloads"))
        #expect(!RingController.allowsFromCLI(.shell("say hi"), rings: []))
    }

    @Test func hudTextIsOnePlainLine() {
        #expect(HUD.sanitized("a\nb\tc\u{1B}[31m") == "a b c[31m")
        #expect(HUD.sanitized("safe\u{202E}txt.exe") == "safetxt.exe")
        #expect(HUD.sanitized(String(repeating: "x", count: 500)).count == 160)
    }

    @Test func jsonStoreIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore<[String]>(url: dir.appending(path: "x.json"))
        store.save(["a"])
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "x.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func socketPathFits() {
        #expect(HopIPC.address(HopIPC.socketURL.path) != nil)
        #expect(HopIPC.address(String(repeating: "x", count: 200)) == nil)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import hop

struct RingTests {
    private func decode(_ json5: String) throws -> HopConfig {
        let d = JSONDecoder()
        d.allowsJSON5 = true
        return try d.decode(HopConfig.self, from: Data(json5.utf8))
    }

    @Test func triggersParse() {
        #expect(RingTrigger.parse("fn") == .fn)
        #expect(RingTrigger.parse("mouse3") == .mouse(2))
        #expect(RingTrigger.parse("Middle") == .mouse(2))
        #expect(RingTrigger.parse("mouse5") == .mouse(4))
        #expect(RingTrigger.parse("tap3") == .tap(3))
        #expect(RingTrigger.parse("tap4") == .tap(4))
        #expect(RingTrigger.parse("tap2") == nil)
        #expect(RingTrigger.parse("") == nil)
        #expect(RingTrigger.parse("hyper+space") == .hotkey(HotkeySpec.parse("hyper+space")!))
        #expect(RingTrigger.parse("nonsense") == nil)
        #expect(RingTrigger.parse("tap3")?.isHeld == false)
        #expect(RingTrigger.parse("fn")?.isHeld == true)
    }

    @Test func actionsParse() {
        #expect(RingActionRef.parse("dark-mode") == .builtin("dark-mode"))
        #expect(RingActionRef.parse("clipboard.history") == .command("clipboard.history"))
        #expect(RingActionRef.parse("app:Safari") == .app("Safari"))
        #expect(RingActionRef.parse("key:cmd+shift+t") == .key(KeyStroke.parse("cmd+shift+t")!))
        #expect(RingActionRef.parse("key:nope+t") == nil)
        #expect(RingActionRef.parse("type:/model opus\\n") == .type("/model opus\n"))
        #expect(RingActionRef.parse("menu:File > New Tab") == .menu(["File", "New Tab"]))
        #expect(RingActionRef.parse("menu:File") == nil)
        #expect(RingActionRef.parse("shortcut:Morning") == .shortcut("Morning"))
        #expect(RingActionRef.parse("https://github.com") == .url("https://github.com"))
        #expect(RingActionRef.parse("raycast://confetti") == .url("raycast://confetti"))
        #expect(RingActionRef.parse("folder:~/Downloads") == .folder("~/Downloads"))
        #expect(RingActionRef.parse("shell:say hi") == .shell("say hi"))
        #expect(RingActionRef.parse("  ") == nil)
    }

    @Test func keystrokesParse() {
        let k = KeyStroke.parse("ctrl+left")!
        #expect(k.flags == .maskControl)
        #expect(KeyStroke.parse("c")?.flags == [])
        #expect(KeyStroke.parse("hyper+k")?.flags == [.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }

    @Test func slicesDecodeAsStringsOrObjects() throws {
        let config = try decode("""
        { rings: { appTrigger: "hyper+a", rings: [
          { name: "Main", trigger: "fn", slices: [
            "dark-mode",
            { title: "Term", icon: "terminal", action: "app:Terminal" },
            { title: "Files", children: ["copy-path", { action: "convert" }] },
          ] },
          { name: "Safari", app: "com.apple.Safari", slices: ["key:cmd+t"] },
        ] } }
        """)
        let r = config.rings
        #expect(r.enabled)
        #expect(r.appTrigger == "hyper+a")
        #expect(r.rings.count == 2)
        let main = r.rings[0]
        #expect(main.slices[0] == HopConfig.Slice(action: "dark-mode"))
        #expect(main.slices[1].title == "Term" && main.slices[1].icon == "terminal" && main.slices[1].action == "app:Terminal")
        #expect(main.slices[2].children.map(\.action) == ["copy-path", "convert"])
        #expect(r.rings[1].app == "com.apple.Safari")
    }

    @Test func ringsConfigHasNoUnknownKeys() {
        let text = """
        { rings: { fireOn: "click", deadZone: "large", size: 150, rings: [
          { name: "Main", trigger: "fn", keepOpen: true, slices: [{ title: "x", icon: "y", action: "mute", children: [] }] },
        ] } }
        """
        #expect(ConfigDiagnostics.warnings(in: text).isEmpty)
        let typo = ConfigDiagnostics.warnings(in: "{ rings: { rings: [ { nmae: \"x\" } ] } }")
        #expect(typo.count == 1)
    }

    @Test func choicesAndScale() throws {
        let r = try decode(#"{ rings: { fireOn: "click", deadZone: "extraLarge", size: 500 } }"#).rings
        #expect(r.fireOn == .click)
        #expect(r.deadZone.radius == 28)
        #expect(r.scale == 2)
        #expect(HopConfig.Rings().scale == 1)
    }

    @Test func layoutAimsAtTheNearestSlice() {
        let l = RingLayout(center: .zero, count: 4, scale: 1, deadZone: 16)
        // Slice 0 at the top, then clockwise: right, bottom, left.
        #expect(l.aimed(at: CGPoint(x: 0, y: 50)) == 0)
        #expect(l.aimed(at: CGPoint(x: 50, y: 5)) == 1)
        #expect(l.aimed(at: CGPoint(x: 3, y: -60)) == 2)
        #expect(l.aimed(at: CGPoint(x: -40, y: 0)) == 3)
        #expect(l.aimed(at: CGPoint(x: 5, y: 5)) == nil) // dead zone
        #expect(!l.isBeyond(CGPoint(x: 0, y: 100)))
        #expect(l.isBeyond(CGPoint(x: 0, y: 200)))
    }

    @Test func fanOnlyAnswersWithinItsArc() {
        // A group's children facing right (+x).
        let l = RingLayout(center: .zero, count: 3, scale: 1, deadZone: 10, facing: 0)
        #expect(l.aimed(at: CGPoint(x: 60, y: 0)) == 1)
        #expect(l.aimed(at: CGPoint(x: 40, y: 30)) == 0)
        #expect(l.aimed(at: CGPoint(x: 40, y: -30)) == 2)
        #expect(l.aimed(at: CGPoint(x: -60, y: 0)) == nil) // back toward the parent
    }

    @Test func everyCatalogIDIsUniqueAndBuiltIn() {
        let ids = RingCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids { #expect(RingActionRef.parse(id) == .builtin(id)) }
    }

    @Test func presetsUseValidActions() {
        for ring in RingPresets.apps + [RingPresets.media] {
            #expect(ring.slices.count <= 8, "\(ring.name)")
            for slice in ring.slices + ring.slices.flatMap(\.children) where slice.children.isEmpty {
                #expect(RingActionRef.parse(slice.action) != nil, "\(ring.name): \(slice.action)")
                if case .command = RingActionRef.parse(slice.action) { Issue.record("\(ring.name): \(slice.action) is not built in") }
            }
        }
    }

    @Test @MainActor func statsCountFlicksAndStreaks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ring-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = RingStats(url: url)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date()).addingTimeInterval(3600 * 12)
        stats.record("dark-mode", ring: "Main", on: cal.date(byAdding: .day, value: -2, to: today)!)
        stats.record("dark-mode", ring: "Main", on: cal.date(byAdding: .day, value: -1, to: today)!)
        stats.record("mute", ring: "Main", on: today)
        #expect(stats.total == 3)
        #expect(stats.data.actions["dark-mode"] == 2)
        #expect(stats.streak(today: today) == 3)
        stats.saveNow()
        #expect(RingStats(url: url).total == 3)
        stats.reset()
        #expect(stats.total == 0)
    }
}

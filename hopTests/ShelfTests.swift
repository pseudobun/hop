import AppKit
import Testing
@testable import hop

struct ShelfTests {
    /// Swings between two x positions, `step` points per sample, 10 ms apart.
    private func swing(_ detector: inout ShakeDetector, amplitude: CGFloat, swings: Int, step: CGFloat = 8,
                       start: TimeInterval = 0, interval: TimeInterval = 0.01) -> Bool {
        var x: CGFloat = 500, t = start, dir: CGFloat = 1
        if detector.add(x: x, time: t) { return true }
        for _ in 0..<swings {
            var moved: CGFloat = 0
            while moved < amplitude {
                x += dir * step
                moved += step
                t += interval
                if detector.add(x: x, time: t) { return true }
            }
            dir = -dir
        }
        return false
    }

    @Test func quickShakeFiresAndResets() {
        var d = ShakeDetector(sensitivity: .medium)
        let r1 = swing(&d, amplitude: 80, swings: 5)
        #expect(r1)
        // Reset after firing: a single small move does not fire again.
        let again = d.add(x: 10, time: 10)
        #expect(!again)
    }

    @Test func steadyDragAndSmallWobbleDoNotShake() {
        var straight = ShakeDetector(sensitivity: .high)
        let r2 = swing(&straight, amplitude: 2000, swings: 1)
        #expect(!r2)
        var wobble = ShakeDetector(sensitivity: .medium)
        let r3 = swing(&wobble, amplitude: 16, swings: 20, step: 4)
        #expect(!r3)
    }

    @Test func slowSwingsDoNotShake() {
        var d = ShakeDetector(sensitivity: .medium)
        // 80 pt swings at 8 pt per 100 ms: one reversal per second, outside the window.
        let r4 = swing(&d, amplitude: 80, swings: 8, interval: 0.1)
        #expect(!r4)
    }

    @Test func sensitivityChangesHowMuchCounts() {
        var high = ShakeDetector(sensitivity: .high)
        let r5 = swing(&high, amplitude: 32, swings: 3, step: 4)
        #expect(r5)
        var low = ShakeDetector(sensitivity: .low)
        let r6 = swing(&low, amplitude: 32, swings: 6, step: 4)
        #expect(!r6)
    }

    @Test func modifierSpecs() {
        #expect(DragWatcher.modifiers("shift") == [.shift])
        #expect(DragWatcher.modifiers("ctrl+Alt") == [.control, .option])
        #expect(DragWatcher.modifiers("") == [])
        #expect(DragWatcher.modifiers("none") == [])
        #expect(DragWatcher.modifiers("shift+banana") == nil)
    }

    @Test func textBecomesLinkOnlyWhenItIsOneWebURL() {
        #expect(ShelfItem.classify("https://example.com/a?b=1").kind == .link)
        #expect(ShelfItem.classify("  http://x.org  ").value == "http://x.org")
        #expect(ShelfItem.classify("see https://example.com").kind == .text)
        #expect(ShelfItem.classify("mailto:me@example.com").kind == .text)
        #expect(ShelfItem.classify("hello").kind == .text)
    }

    @Test func titlesAndSummary() {
        #expect(ShelfItem.link("https://github.com/lutralabs/hop").title == "github.com/lutralabs/hop")
        #expect(ShelfItem.link("https://example.com/").title == "example.com")
        #expect(ShelfItem.text("\n  first line \nsecond").title == "first line")
        let items: [ShelfItem] = [.file("/a"), .file("/b"), .link("https://x.org"), .text("t")]
        #expect(ShelfStackTile.summary(items) == "2 files · 1 link · 1 text")
        #expect(ShelfItem.file("/a").sameContent(as: .file("/a")))
        #expect(!ShelfItem.file("/a").sameContent(as: .text("/a")))
    }

    @Test func readsFilesBeforeTextFromAPasteboard() {
        let pb = NSPasteboard(name: .init("hop.tests.shelf"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp") as NSURL])
        #expect(ShelfItem.items(from: pb).map(\.kind) == [.file])
        pb.clearContents()
        pb.setString("https://example.com", forType: .string)
        #expect(ShelfItem.items(from: pb).map(\.kind) == [.link])
        pb.clearContents()
        pb.setString("   ", forType: .string)
        #expect(ShelfItem.items(from: pb).isEmpty)
        pb.releaseGlobally()
    }

    @Test func configDefaultsAndOverrides() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let defaults = try decoder.decode(HopConfig.self, from: Data("{}".utf8)).shelf
        #expect(defaults.enabled && defaults.shake && defaults.modifier == "shift" && defaults.shakeSensitivity == .medium)
        let custom = try decoder.decode(HopConfig.self, from: Data("{shelf: {shake: false, shakeSensitivity: 'high', modifier: '', hotkey: 'hyper+d'}}".utf8)).shelf
        #expect(!custom.shake && custom.shakeSensitivity == .high && custom.modifier.isEmpty && custom.hotkey == "hyper+d")
        // The template parses and keeps the defaults.
        #expect(try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8)).shelf == HopConfig.Shelf())
    }
}

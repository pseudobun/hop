#if DEBUG
import AppKit

/// Debug-only: `-DebugBenchmark YES` times showing the panel and typing, prints the
/// numbers and quits. Build with `SWIFT_OPTIMIZATION_LEVEL=-O` for realistic timings.
enum DebugBenchmark {
    static func run(_ launcher: LauncherController, probes: [(String, () -> Void)]) async {
        // Let the app index finish (and a profiler attach: `-DebugBenchmarkDelay 8`).
        let delay = max(3, UserDefaults.standard.double(forKey: "DebugBenchmarkDelay"))
        try? await Task.sleep(for: .seconds(delay))

        measure("first show", runs: 1) { show(launcher) }
        launcher.hide()
        IconCache.shared.purge()
        measure("show with cold icon cache", runs: 1) { show(launcher) }
        launcher.hide()
        measure("show + hide") { show(launcher); launcher.hide() }

        show(launcher)
        for query in ["safari", "terminal", "sys set", "12*3+4", "10 km to mi"] {
            let prefixes = query.indices.map { String(query[...$0]) }
            measure("type \"\(query)\" (\(prefixes.count) keys)") {
                for q in prefixes { launcher.setQuery(q); launcher.panel.displayIfNeeded() }
                launcher.setQuery("")
            }
        }
        measure("clear to empty query") { launcher.setQuery("s"); launcher.setQuery("") }

        // `-DebugBenchmarkSnapshots <dir>`: what the panel shows after typing, to check that
        // reconfiguring cells in place leaves nothing stale.
        if let dir = UserDefaults.standard.string(forKey: "DebugBenchmarkSnapshots") {
            for query in ["terminal", "sys set", "saf", "12*3+4", ""] {
                for q in query.indices.map({ String(query[...$0]) }) { launcher.setQuery(q) }
                if query.isEmpty { launcher.setQuery("") }
                await DebugSnapshot.capture(launcher.panel, to: "\(dir)/\(query.isEmpty ? "empty" : query).png")
            }
        }
        launcher.hide()

        for (label, probe) in probes { measure(label, probe) }
        exit(0)
    }

    private static func show(_ launcher: LauncherController) {
        launcher.show()
        launcher.panel.displayIfNeeded()
    }

    private static func measure(_ label: String, runs: Int = 25, _ body: () -> Void) {
        var ms: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            ms.append((ContinuousClock.now - start) / .milliseconds(1))
        }
        ms.sort()
        let name = label.padding(toLength: 34, withPad: " ", startingAt: 0)
        print(String(format: "%@ median %7.2f ms   p90 %7.2f ms   max %7.2f ms",
                     name, ms[ms.count / 2], ms[ms.count * 9 / 10], ms.last!))
    }
}
#endif

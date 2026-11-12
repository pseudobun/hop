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
        launcher.setQuery("s")
        measure("move ↓↓↓↓↓ ↑↑↑↑↑ (10 keys)") {
            for step in [1, 1, 1, 1, 1, -1, -1, -1, -1, -1] { launcher.debugMove(step); launcher.panel.displayIfNeeded() }
        }
        launcher.setQuery("")

        // `-DebugBenchmarkSnapshots <dir>`: what the panel shows after typing, to check that
        // reconfiguring cells in place leaves nothing stale.
        if let dir = UserDefaults.standard.string(forKey: "DebugBenchmarkSnapshots") {
            try? await Task.sleep(for: .milliseconds(300)) // the show's fade-in, held up by the timings
            for query in ["terminal", "sys set", "saf", "12*3+4", ""] {
                for q in query.indices.map({ String(query[...$0]) }) { launcher.setQuery(q) }
                if query.isEmpty { launcher.setQuery("") }
                await DebugSnapshot.capture(launcher.panel, to: "\(dir)/\(query.isEmpty ? "empty" : query).png")
            }
            // The gliding highlight lands on the third result after two ↓.
            launcher.setQuery("s")
            try? await Task.sleep(for: .seconds(1)) // results that arrive later reselect the first row
            launcher.debugMove(1); launcher.debugMove(1)
            try? await Task.sleep(for: .milliseconds(400))
            await DebugSnapshot.capture(launcher.panel, to: "\(dir)/s-down2.png")
            launcher.setQuery("")
        }
        launcher.hide()

        for (label, probe) in probes { measure(label, probe) }

        // `-DebugBenchmarkSoak N`: run every scenario N more times and report the footprint
        // before and after, to catch memory that grows with use.
        let soak = UserDefaults.standard.integer(forKey: "DebugBenchmarkSoak")
        // `-DebugBenchmarkSoakOnly <text>`: soak only the scenarios whose label contains it
        // ("launcher" for showing and typing in the launcher).
        let only = UserDefaults.standard.string(forKey: "DebugBenchmarkSoakOnly")
        let soakLauncher = only == nil || only == "launcher"
        let soakProbes = probes.filter { only == nil || $0.0.contains(only!) }
        if soak > 0 {
            let before = footprintMB()
            for _ in 0..<soak {
                // Back to the run loop between rounds, as between real keystrokes: work that
                // AppKit defers to it (layout, CA commits, main-queue blocks) runs and frees.
                try? await Task.sleep(for: .milliseconds(20))
                autoreleasepool {
                if soakLauncher {
                    show(launcher)
                    for query in ["safari", "terminal", "sys set", "12*3+4", "10 km to mi"] {
                        for q in query.indices.map({ String(query[...$0]) }) { launcher.setQuery(q) }
                        launcher.setQuery("")
                    }
                    launcher.hide()
                }
                for (_, probe) in soakProbes { autoreleasepool { probe() } }
            } }
            try? await Task.sleep(for: .seconds(1))
            print(String(format: "footprint after warm-up %.1f MB, after %d soak rounds %.1f MB", before, soak, footprintMB()))
        }
        print(String(format: "footprint %.1f MB (peak %.1f MB)", footprintMB(), footprintMB(peak: true)))
        // `-DebugBenchmarkStay YES`: keep running so `leaks`, `heap` or `footprint` can look.
        if UserDefaults.standard.bool(forKey: "DebugBenchmarkStay") {
            print("pid \(ProcessInfo.processInfo.processIdentifier) stays up")
            fflush(stdout)
            return
        }
        exit(0)
    }

    static func footprintMB(peak: Bool = false) -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return (peak ? Double(info.ledger_phys_footprint_peak) : Double(info.phys_footprint)) / 1_048_576
    }

    private static func show(_ launcher: LauncherController) {
        launcher.show()
        launcher.panel.displayIfNeeded()
    }

    private static func measure(_ label: String, runs: Int = 25, _ body: () -> Void) {
        var ms: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            // Each run drains its own pool, as a run-loop turn would after a real keystroke.
            autoreleasepool { body() }
            ms.append((ContinuousClock.now - start) / .milliseconds(1))
        }
        ms.sort()
        let name = label.padding(toLength: 34, withPad: " ", startingAt: 0)
        print(String(format: "%@ median %7.2f ms   p90 %7.2f ms   max %7.2f ms   %6.1f MB",
                     name, ms[ms.count / 2], ms[ms.count * 9 / 10], ms.last!, footprintMB()))
    }
}
#endif

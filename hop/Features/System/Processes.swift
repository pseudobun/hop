import AppKit

nonisolated struct RunningProcess: Sendable, Equatable {
    let pid: Int32
    let uid: UInt32
    let cpu: Double
    /// Resident memory in bytes.
    let memory: Int64
    let path: String

    var name: String { (path as NSString).lastPathComponent }
}

nonisolated enum Processes {
    /// `ps -axo pid=,uid=,pcpu=,rss=,comm=` → processes, biggest CPU users first.
    static func parse(_ output: String, excluding excluded: Set<Int32> = []) -> [RunningProcess] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let uid = UInt32(f[1]),
                  let cpu = Double(f[2].replacingOccurrences(of: ",", with: ".")), let rss = Int64(f[3]),
                  pid > 1, !excluded.contains(pid)
            else { return nil }
            return RunningProcess(pid: pid, uid: uid, cpu: cpu, memory: rss * 1024, path: String(f[4]))
        }
        .sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
    }

    /// Leaves out the calling process unless `includingSelf`, so `hop kill hop` can't hit the CLI itself.
    static func list(includingSelf: Bool = false) async -> [RunningProcess] {
        let r = try? await ProcessRunner.run("/bin/ps", ["-axo", "pid=,uid=,pcpu=,rss=,comm="], timeout: .seconds(10))
        return parse(r?.out ?? "", excluding: includingSelf ? [] : [ProcessInfo.processInfo.processIdentifier])
    }

    enum KillResult: Equatable { case ok, notPermitted, gone, failed }

    static func kill(_ pid: Int32, force: Bool) -> KillResult {
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .ok }
        switch errno {
        case EPERM: return .notPermitted
        case ESRCH: return .gone
        default: return .failed
        }
    }

    /// `kill -9` with an administrator password prompt, for other users' processes.
    static func killAsAdmin(_ pid: Int32) async -> Bool {
        let r = try? await AppleScript.run("do shell script \"/bin/kill -9 \(pid)\" with administrator privileges")
        return r?.ok == true
    }
}

/// "Kill Process": search running processes; ↵ quits (SIGTERM), ⇧↵ force-kills.
final class KillProcessMode: Mode {
    let title: String? = "Kill Process"
    let tint: NSColor? = Theme.destructive
    let placeholder = "Search processes by name or PID…"
    private let sensitivity: Sensitivity
    private var processes: [RunningProcess] = []
    private var apps: [Int32: NSRunningApplication] = [:]
    private weak var context: LauncherContext?

    init(sensitivity: Sensitivity) { self.sensitivity = sensitivity }

    func didEnter(_ context: LauncherContext) {
        self.context = context
        reloadList()
    }

    private func reloadList(after delay: Duration? = nil) {
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            context?.setLoading(true)
            processes = await Processes.list(includingSelf: true)
            apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            context?.setLoading(false)
            context?.reload()
        }
    }

    private func displayName(_ p: RunningProcess) -> String { apps[p.pid]?.localizedName ?? p.name }

    func sections(for query: String) -> [ResultSection] {
        var list = processes
        let q = query.trimmingCharacters(in: .whitespaces)
        if let pid = Int32(q) {
            list = list.filter { String($0.pid).hasPrefix(String(pid)) }
        } else if !q.isEmpty {
            let cands = list.map { RankCandidate(id: String($0.pid), title: displayName($0), alternateTitles: [$0.name], typeWeight: 1) }
            list = RootRanker.rank(cands, query: SearchQuery(q), sensitivity: sensitivity).map { list[$0] }
        }
        let me = getuid()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let items = list.prefix(300).map { p in
            let app = apps[p.pid]
            let mem = ByteCountFormatter.string(fromByteCount: p.memory, countStyle: .memory)
            let owner = p.uid == me ? "" : (p.uid == 0 ? " · root" : " · uid \(p.uid)")
            // Killing hop from hop: restart or quit cleanly instead.
            var actions = p.pid == ownPID ? [HopApp.restartAction(), HopApp.quitAction(shortcut: .ret(.shift))] : [
                Action(title: "Kill Process") { [weak self] in await self?.kill(p, force: false) ?? .stay },
                Action(title: "Force Kill", shortcut: .ret(.shift), style: .destructive) { [weak self] in
                    await self?.kill(p, force: true) ?? .stay
                },
            ]
            actions += [
                Action(title: "Copy PID", shortcut: .cmd("c", .shift)) {
                    Pasteboard.copy(String(p.pid))
                    return .stayWithHUD("Copied PID \(p.pid)")
                },
                Action(title: "Show in Finder", shortcut: .ret(.command)) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
                    return .dismiss
                },
            ]
            if p.uid != me {
                actions.append(Action(title: "Force Kill as Administrator", shortcut: .ret([.shift, .option]), style: .destructive) { [weak self] in
                    self?.context?.suppressAutoHide = true
                    let ok = await Processes.killAsAdmin(p.pid)
                    self?.context?.suppressAutoHide = false
                    self?.reloadList(after: .milliseconds(400))
                    return ok ? .stayWithHUD("Killed \(p.name)") : .stayWithHUD("Could not kill \(p.name)")
                })
            }
            return Item(id: "proc.\(p.pid)", title: displayName(p), subtitle: "PID \(p.pid)",
                        icon: app?.bundleURL.map { .file($0.path) } ?? .tile(p.uid == 0 ? "lock.fill" : "terminal.fill", p.uid == 0 ? Theme.chart5 : Palette.neutral),
                        accessory: String(format: "%.1f%% · %@%@", p.cpu, mem, owner),
                        actions: actions, tracksFrecency: false)
        }
        return [ResultSection(title: "Processes", items: Array(items))]
    }

    private func kill(_ p: RunningProcess, force: Bool) async -> ActionResult {
        let result = Processes.kill(p.pid, force: force)
        reloadList(after: .milliseconds(400))
        switch result {
        case .ok: return .stayWithHUD("\(force ? "Force killed" : "Killed") \(displayName(p))")
        case .gone: return .stayWithHUD("\(displayName(p)) already exited")
        case .notPermitted: return .stayWithHUD("Not permitted. Use Force Kill as Administrator (⇧⌥↵)")
        case .failed: return .stayWithHUD("Could not kill \(displayName(p))")
        }
    }
}

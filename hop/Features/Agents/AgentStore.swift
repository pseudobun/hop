import Darwin
import Foundation

/// Finds agent sessions and keeps them current while the panel is open: FSEvents on
/// Claude Code's and OpenCode's folders (nothing is polled), a slow timer for SSH hosts.
/// Closed, it watches nothing.
final class AgentStore {
    private(set) var sessions: [AgentSession] = []
    /// Problems from the last refresh, e.g. an unreachable host; shown in the panel.
    private(set) var hostErrors: [String: String] = [:]
    var onChange: (() -> Void)?
    /// A session's transcript changed on disk (its `key`).
    var onTranscriptChange: ((String) -> Void)?
    var config: () -> HopConfig.Agents = { HopConfig.Agents() }

    private var stream: FSEventStreamRef?
    private var remoteTimer: Timer?
    private var refreshing = false
    private var refreshPending = false
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var remote: [String: [AgentSession]] = [:]
    private var remoteInFlight = Set<String>()
    /// Session key whose transcript the panel shows; FSEvents on it reload just the detail.
    var watchedKey: String?

    nonisolated private static let queue = DispatchQueue(label: "hop.agents", qos: .userInitiated)
    /// Parsed transcript tails by path, valid while the file's mtime and size match.
    nonisolated(unsafe) private static var summaries: [String: (stamp: FileStamp, summary: ClaudeSessions.Summary)] = [:]

    nonisolated struct FileStamp: Equatable, Sendable {
        var modified: Date
        var size: Int

        static func of(_ path: String) -> FileStamp? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let m = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
            return FileStamp(modified: m, size: s)
        }
    }

    var isWatching: Bool { stream != nil }

    // MARK: - Lifetime

    func start() {
        guard stream == nil else { return }
        startStream()
        refresh(force: true)
        refreshRemote()
        let seconds = max(5, config().remoteRefreshSeconds)
        if !config().hosts.isEmpty {
            let t = Timer(timeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRemote() }
            }
            t.tolerance = Double(seconds) / 3
            RunLoop.main.add(t, forMode: .common)
            remoteTimer = t
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
        refreshTask?.cancel()
    }

    private func startStream() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let store = Unmanaged<AgentStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.changed(Array(list.prefix(count))) }
        }
        let claude = ClaudeSessions.home.path
        let opencode = OpenCodeSessions.database.deletingLastPathComponent().path
        let paths = [claude + "/sessions", claude + "/projects", opencode].filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.4, FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func changed(_ paths: [String]) {
        var list = false
        for p in paths {
            if p.contains("/.claude/sessions/") || p.hasSuffix(".db-wal") || p.hasSuffix(".db") {
                list = true
            } else if p.hasSuffix(".jsonl") {
                list = true
                if let key = watchedKey, let s = sessions.first(where: { $0.key == key }), s.transcript == p {
                    onTranscriptChange?(key)
                }
            }
        }
        if paths.contains(where: { $0.hasSuffix(".db-wal") }), let key = watchedKey,
           let s = sessions.first(where: { $0.key == key }), s.provider == .opencode, s.isLocal {
            onTranscriptChange?(key)
        }
        if list { refresh() }
    }

    // MARK: - Refresh

    /// Local sessions again; at most once a second while files keep changing.
    func refresh(force: Bool = false) {
        if refreshing {
            refreshPending = true
            return
        }
        let wait = force ? 0 : max(0, 1.0 - Date().timeIntervalSince(lastRefresh))
        refreshing = true
        refreshTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            guard let self, !Task.isCancelled else {
                self?.refreshing = false
                return
            }
            let config = config()
            let tmux = await Self.tmuxPanes(tmux: AgentTools.tmux(config))
            let local = await Self.localSessions(config: config, panes: tmux)
            lastRefresh = Date()
            refreshing = false
            publish(local: local)
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    private var local: [AgentSession] = []

    @discardableResult
    private func publish(local: [AgentSession]? = nil) -> Bool {
        if let local { self.local = local }
        let all = (self.local + remote.values.flatMap { $0 }).sorted(by: AgentSession.ordered)
        guard all != sessions else { return false }
        sessions = all
        onChange?()
        return true
    }

    func refreshRemote() {
        let hosts = config().hosts.filter { !$0.ssh.isEmpty }
        let labels = Set(hosts.map(\.label))
        for key in remote.keys where !labels.contains(key) { remote[key] = nil }
        for host in hosts where !remoteInFlight.contains(host.label) {
            remoteInFlight.insert(host.label)
            Task { [weak self] in
                let result = await Self.remoteSessions(host)
                guard let self else { return }
                remoteInFlight.remove(host.label)
                let before = hostErrors
                switch result {
                case .success(let list):
                    remote[host.label] = list
                    hostErrors[host.label] = nil
                case .failure(let message):
                    remote[host.label] = []
                    hostErrors[host.label] = message.text
                }
                let changed = publish()
                if !changed && before != hostErrors { onChange?() }
            }
        }
    }

    // MARK: - Local sessions

    nonisolated static func tmuxPanes(tmux: String?) async -> [TmuxPane] {
        guard let tmux else { return [] }
        guard let r = try? await ProcessRunner.run(tmux, ["list-panes", "-a", "-F", TmuxPane.format], timeout: .seconds(3)), r.ok
        else { return [] }
        return TmuxPane.parse(r.out)
    }

    nonisolated static func localSessions(config: HopConfig.Agents, panes: [TmuxPane]) async -> [AgentSession] {
        var claude: [AgentSession] = []
        if config.claude.enabled {
            claude = await withCheckedContinuation { done in
                queue.async { done.resume(returning: claudeSessions(historyHours: config.historyHours)) }
            }
        }
        var opencode: [AgentSession] = []
        if config.opencode.enabled {
            let since = Date().addingTimeInterval(-Double(max(1, config.historyHours)) * 3600)
            let rows = await OpenCodeSessions.sessions(since: since)
            let live = rows.contains { !OpenCodeSessions.isBusy($0) } ? OpenCodeSessions.processDirectories() : []
            for row in rows {
                var pending: String?
                if OpenCodeSessions.isBusy(row) {
                    pending = OpenCodeSessions.entries(await OpenCodeSessions.messages(session: row.id)).pendingTool
                }
                opencode.append(OpenCodeSessions.session(row, liveDirectories: live, pendingTool: pending))
            }
        }
        return attach(panes: panes, to: claude + opencode, host: nil)
    }

    /// Maps tmux panes onto sessions (by process, or for OpenCode by folder) and adds a row
    /// for each hop-started tmux session nothing claimed yet (an agent still starting up).
    nonisolated static func attach(panes: [TmuxPane], to sessions: [AgentSession], host: String?,
                                   parent: (Int32) -> Int32? = AgentStore.parentPID) -> [AgentSession] {
        var out = sessions
        var claimed = Set<String>()
        for i in out.indices {
            if let name = out[i].tmux {
                claimed.insert(name)
            } else if let pid = out[i].pid {
                let pp = host == nil ? parent(pid) : nil
                if let pane = panes.first(where: { $0.pid == pid || (pp != nil && $0.pid == pp) }) {
                    out[i].tmux = pane.session
                    claimed.insert(pane.session)
                }
            } else if out[i].provider == .opencode, out[i].status != .finished,
                      let pane = panes.first(where: { AgentNames.provider(ofTmux: $0.session) == .opencode && $0.path == out[i].cwd
                          && !claimed.contains($0.session) }) {
                out[i].tmux = pane.session
                claimed.insert(pane.session)
            }
        }
        var seen = Set<String>()
        for pane in panes where !claimed.contains(pane.session) && !seen.contains(pane.session) {
            guard let provider = AgentNames.provider(ofTmux: pane.session) else { continue }
            seen.insert(pane.session)
            out.append(AgentSession(provider: provider, id: "tmux:\(pane.session)", host: host, title: pane.session, cwd: pane.path,
                                    status: .running, lastActivity: pane.created ?? .distantPast, pid: pane.pid, tmux: pane.session, bridgeID: nil,
                                    transcript: nil, detail: nil, model: nil))
        }
        return out
    }

    nonisolated static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// Blocking: registry, live transcripts and recent finished ones.
    nonisolated static func claudeSessions(historyHours: Int) -> [AgentSession] {
        let records = ClaudeSessions.liveRecords()
        var out: [AgentSession] = []
        var live = Set<String>()
        for r in records {
            live.insert(r.sessionID)
            let url = ClaudeSessions.transcriptURL(sessionID: r.sessionID, cwd: r.cwd)
            out.append(ClaudeSessions.session(r, summary: url.flatMap { summary($0, bytes: 384 * 1024) }, transcript: url))
        }
        let since = Date().addingTimeInterval(-Double(max(1, historyHours)) * 3600)
        for (url, modified) in ClaudeSessions.recentTranscripts(since: since) {
            let id = url.deletingPathExtension().lastPathComponent
            guard !live.contains(id), let s = summary(url, bytes: 64 * 1024), !s.entries.isEmpty || s.title != nil else { continue }
            out.append(ClaudeSessions.finished(url, modified: modified, summary: s))
        }
        return out
    }

    /// A transcript tail, parsed again only when the file changed.
    nonisolated static func summary(_ url: URL, bytes: Int) -> ClaudeSessions.Summary? {
        guard let stamp = FileStamp.of(url.path) else { return nil }
        let key = "\(bytes):\(url.path)"
        if let hit = summaries[key], hit.stamp == stamp { return hit.summary }
        guard let data = ClaudeSessions.tail(of: url, bytes: bytes) else { return nil }
        let s = ClaudeSessions.parse(data)
        if summaries.count > 200 { summaries.removeAll() }
        summaries[key] = (stamp, s)
        return s
    }

    // MARK: - Remote sessions

    nonisolated struct Failure: Error { let text: String }

    nonisolated static func remoteSessions(_ host: HopConfig.Agents.Host) async -> Result<[AgentSession], Failure> {
        guard let r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh),
                                                   stdin: Data(AgentCommands.remoteListScript.utf8), timeout: .seconds(12))
        else { return .failure(Failure(text: "ssh could not start")) }
        guard r.ok else {
            let line = r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.status)"
            return .failure(Failure(text: line))
        }
        let list = AgentCommands.parseRemoteList(r.out)
        let sessions = list.records.map { ClaudeSessions.session($0, summary: nil, transcript: nil, host: host.label) }
        // Remote processes are not ours to inspect: match tmux panes by pid only.
        return .success(attach(panes: list.panes, to: sessions, host: host.label, parent: { _ in nil }))
    }

    // MARK: - Transcripts

    /// The selected session's latest messages and tool calls.
    func entries(for s: AgentSession) async -> [TranscriptEntry] {
        switch (s.provider, s.isLocal) {
        case (.claude, true):
            guard let path = s.transcript else { return [] }
            return await withCheckedContinuation { done in
                Self.queue.async { done.resume(returning: Self.summary(URL(fileURLWithPath: path), bytes: 384 * 1024)?.entries ?? []) }
            }
        case (.opencode, true):
            guard !s.id.hasPrefix("tmux:") else { return [] }
            return OpenCodeSessions.entries(await OpenCodeSessions.messages(session: s.id)).entries
        case (.claude, false):
            guard !s.id.hasPrefix("tmux:"), let host = config().hosts.first(where: { $0.label == s.host }) else { return [] }
            guard let r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh),
                                                       stdin: Data(AgentCommands.remoteTranscriptScript(sessionID: s.id).utf8),
                                                       timeout: .seconds(12)), r.ok else { return [] }
            var data = r.stdout
            if let nl = data.firstIndex(of: UInt8(ascii: "\n")) { data = Data(data[(nl + 1)...]) }
            return ClaudeSessions.parse(data).entries
        case (.opencode, false):
            return []
        }
    }

    /// Folders to offer when starting a session on this Mac: where sessions ran, Claude
    /// Code's known projects, then subfolders of `projectRoots`.
    func recentProjects(host: HopConfig.Agents.Host?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ p: String) {
            let path = host == nil ? (p as NSString).abbreviatingWithTildeInPath : p
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            out.append(path)
        }
        if let host {
            sessions.filter { $0.host == host.label }.forEach { add($0.cwd) }
            host.projects.forEach(add)
            add(host.cwd)
            return out
        }
        sessions.filter(\.isLocal).forEach { add($0.cwd) }
        let fm = FileManager.default
        if let data = try? Data(contentsOf: fm.homeDirectoryForCurrentUser.appending(path: ".claude.json")),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let projects = o["projects"] as? [String: Any] {
            projects.keys.sorted().filter { fm.fileExists(atPath: $0) && !$0.contains("/Library/") }.forEach(add)
        }
        for root in config().projectRoots {
            let dir = root.expandingTilde
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names.sorted() where !n.hasPrefix(".") {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir + "/" + n, isDirectory: &isDir), isDir.boolValue { add(dir + "/" + n) }
            }
        }
        return out
    }
}

/// Where the binaries are. hop starts from launchd with a short PATH, so it asks the
/// login shell for the real one once.
nonisolated enum AgentTools {
    nonisolated(unsafe) private static var cachedPath: String?

    /// PATH from `$SHELL -l -c env` (works for fish, zsh and bash alike).
    static func loginPath() async -> String {
        if let cachedPath { return cachedPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let r = try? await ProcessRunner.run(shell, ["-l", "-c", "/usr/bin/env"], timeout: .seconds(6)), r.ok,
           let line = r.out.split(separator: "\n").first(where: { $0.hasPrefix("PATH=") }) {
            path = String(line.dropFirst(5))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !path.contains("\(home)/.local/bin") { path = "\(home)/.local/bin:" + path }
        cachedPath = path
        return path
    }

    static func find(_ configured: String, candidates: [String], name: String, path: String? = nil) -> String? {
        let fm = FileManager.default
        if !configured.isEmpty {
            let p = configured.expandingTilde
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        let dirs = (path ?? cachedPath ?? "").split(separator: ":").map { "\($0)/\(name)" }
        return (candidates.map(\.expandingTilde) + dirs).first { fm.isExecutableFile(atPath: $0) }
    }

    static func tmux(_ c: HopConfig.Agents) -> String? {
        find(c.tmux, candidates: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"], name: "tmux")
    }

    static func binary(_ provider: AgentProvider, _ c: HopConfig.Agents, path: String? = nil) -> String? {
        switch provider {
        case .claude:
            find(c.claude.binary, candidates: ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                 name: "claude", path: path)
        case .opencode:
            find(c.opencode.binary, candidates: ["/opt/homebrew/bin/opencode", "~/.opencode/bin/opencode", "~/.local/bin/opencode", "/usr/local/bin/opencode"],
                 name: "opencode", path: path)
        }
    }
}

import Foundation

/// Claude Code's on-disk state: `~/.claude/sessions/<pid>.json` (one per running process,
/// rewritten in place as its status changes) and `~/.claude/projects/<cwd>/<id>.jsonl`
/// transcripts. Read only.
nonisolated enum ClaudeSessions {
    /// A `sessions/<pid>.json` record.
    struct Record: Equatable, Sendable {
        var pid: Int32
        var sessionID: String
        var cwd: String
        var kind: String
        var name: String?
        var status: String?
        var updatedAt: Date?
        var startedAt: Date?
        var bridgeSessionID: String?
        /// The tmux session Claude Code says it runs in.
        var tmux: String?
        /// "cli", or "sdk-cli" for processes another program drives (a `claude rc` child).
        var entrypoint: String? = nil
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude") }
    static var registryDir: URL { home.appending(path: "sessions") }
    static var projectsDir: URL { home.appending(path: "projects") }

    // MARK: - Registry

    static func parseRecord(_ data: Data) -> Record? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionID = o["sessionId"] as? String,
              let pid = (o["pid"] as? NSNumber)?.int32Value else { return nil }
        func date(_ key: String) -> Date? { (o[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        return Record(pid: pid, sessionID: sessionID, cwd: o["cwd"] as? String ?? "", kind: o["kind"] as? String ?? "interactive",
                      name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, status: o["status"] as? String,
                      updatedAt: date("updatedAt") ?? date("statusUpdatedAt"), startedAt: date("startedAt"),
                      bridgeSessionID: (o["bridgeSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      tmux: tmuxSessionName(o["tmux"] as? String), entrypoint: o["entrypoint"] as? String)
    }

    /// Records whose process is still alive; the supervising `daemon` itself is left out.
    static func liveRecords(in dir: URL = registryDir, isAlive: (Int32) -> Bool = processAlive) -> [Record] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> Record? in
            guard name.hasSuffix(".json"), Int32(name.dropLast(5)) != nil,
                  let data = try? Data(contentsOf: dir.appending(path: name)),
                  let r = parseRecord(data), r.kind != "daemon", isAlive(r.pid) else { return nil }
            return r
        }
    }

    /// The session part of what Claude Code records ("name", "name:0.1"); pane ids ("%3") say nothing.
    static func tmuxSessionName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("%") else { return nil }
        let name = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        return name.isEmpty ? nil : name
    }

    static func processAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    // MARK: - Remote Control server mode

    /// The claude.ai session a `claude rc` child serves. The server starts each one headless as
    /// `claude --print --sdk-url https://…/v1/code/sessions/cse_… --session-id cse_… …`.
    static func remoteControlID(arguments: [String]) -> String? {
        for (i, a) in arguments.enumerated() {
            if a == "--sdk-url", i + 1 < arguments.count { return remoteControlID(sdkURL: arguments[i + 1]) }
            if a.hasPrefix("--sdk-url=") { return remoteControlID(sdkURL: String(a.dropFirst("--sdk-url=".count))) }
        }
        return nil
    }

    /// Same, from a `ps -o args=` line.
    static func remoteControlID(commandLine: String) -> String? {
        remoteControlID(arguments: commandLine.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// "cse_…" from an `--sdk-url` value (`…/code/sessions/cse_…`, or the session_ spelling).
    static func remoteControlID(sdkURL: String) -> String? {
        guard let m = sdkURL.firstMatch(of: /\/sessions\/(cse|session)_([A-Za-z0-9_-]+)/) else { return nil }
        return "cse_" + m.2
    }

    /// The id claude.ai/code links use: Claude Code turns "cse_" into "session_" (same body).
    static func compatSessionID(_ id: String) -> String {
        id.hasPrefix("cse_") ? "session_" + id.dropFirst(4) : id
    }

    /// The registry's bridge id in "cse_" spelling.
    static func infraSessionID(_ id: String) -> String {
        id.hasPrefix("session_") ? "cse_" + id.dropFirst(8) : id
    }

    // MARK: - Transcripts

    /// The folder name Claude Code gives a working directory: every character that is not
    /// a letter or digit becomes "-".
    static func encodedProjectName(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    /// The transcript of a session, found by its cwd or, failing that, by any project folder.
    static func transcriptURL(sessionID: String, cwd: String, projects: URL = projectsDir) -> URL? {
        let fm = FileManager.default
        let direct = projects.appending(path: encodedProjectName(cwd)).appending(path: "\(sessionID).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return nil }
        for d in dirs {
            let u = projects.appending(path: d).appending(path: "\(sessionID).jsonl")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Top-level transcripts changed since `since`, newest first.
    static func recentTranscripts(since: Date, projects: URL = projectsDir, limit: Int = 60) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [(URL, Date)] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension == "jsonl" && !f.lastPathComponent.hasPrefix("agent-") {
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > since
                else { continue }
                found.append((f, m))
            }
        }
        return Array(found.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// The last `bytes` of a file, starting at a line boundary.
    static func tail(of url: URL, bytes: Int = 384 * 1024) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[(nl + 1)...] }
        return Data(data)
    }

    /// What the panel needs from a transcript's tail.
    struct Summary: Equatable, Sendable {
        var entries: [TranscriptEntry] = []
        /// /rename or the agent name, else the last prompt.
        var title: String?
        var lastPrompt: String?
        var cwd: String?
        var model: String?
        var lastActivity: Date?
        /// A tool call that has no result yet: the session is running it or waiting for permission.
        var pendingTool: String?
    }

    /// Parses JSONL lines (oldest first). Keeps the last `limit` entries.
    static func parse(_ data: Data, limit: Int = 80) -> Summary {
        var s = Summary()
        var customTitle: String?, agentName: String?
        var answered = Set<String>()
        var calls: [(id: String, name: String)] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            // Attachments and system lines carry it too; a tail may hold nothing else.
            if let cwd = o["cwd"] as? String, !cwd.isEmpty, o["isSidechain"] as? Bool != true { s.cwd = cwd }
            switch type {
            case "custom-title": customTitle = (o["customTitle"] as? String) ?? customTitle
            case "agent-name": agentName = (o["agentName"] as? String) ?? agentName
            case "last-prompt": s.lastPrompt = (o["lastPrompt"] as? String) ?? s.lastPrompt
            case "user", "assistant":
                if o["isSidechain"] as? Bool == true { continue }
                let date = (o["timestamp"] as? String).flatMap(parseDate)
                if let date { s.lastActivity = date }
                guard let message = o["message"] as? [String: Any] else { continue }
                if type == "assistant", let model = message["model"] as? String, !model.hasPrefix("<") { s.model = model }
                let meta = o["isMeta"] as? Bool == true
                if let text = message["content"] as? String {
                    if type == "user" && !meta { appendUser(text, date, &s) }
                    continue
                }
                for part in message["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "text":
                        let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        if type == "assistant" {
                            s.entries.append(TranscriptEntry(kind: .assistant, text: text, date: date))
                        } else if !meta {
                            appendUser(text, date, &s)
                        }
                    case "tool_use":
                        let name = part["name"] as? String ?? "tool"
                        let id = part["id"] as? String
                        s.entries.append(TranscriptEntry(kind: .tool(name: name), text: toolSummary(name, part["input"] as? [String: Any]),
                                                         date: date, toolID: id))
                        if let id { calls.append((id, name)) }
                    case "tool_result":
                        if let id = part["tool_use_id"] as? String { answered.insert(id) }
                        let isError = part["is_error"] as? Bool == true
                        let text = resultText(part["content"])
                        s.entries.append(TranscriptEntry(kind: .result(isError: isError), text: text, date: date))
                    default: break
                    }
                }
            default: break
            }
        }
        if s.entries.count > limit { s.entries.removeFirst(s.entries.count - limit) }
        s.title = [customTitle, agentName].compactMap { $0 }.first { !$0.isEmpty }
        s.pendingTool = calls.last.flatMap { answered.contains($0.id) ? nil : $0.name }
        return s
    }

    private static func appendUser(_ raw: String, _ date: Date?, _ s: inout Summary) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Slash commands and their output come wrapped in tags; system reminders are noise.
        if text.hasPrefix("<command-name>") {
            let name = text.firstMatch(of: /<command-name>([^<]*)<\/command-name>/).map { String($0.1) } ?? "command"
            s.entries.append(TranscriptEntry(kind: .notice, text: name, date: date))
            return
        }
        if text.hasPrefix("<") && (text.hasPrefix("<local-command") || text.hasPrefix("<system-reminder") || text.hasPrefix("<command-")) { return }
        if text.hasPrefix("[Request interrupted") {
            s.entries.append(TranscriptEntry(kind: .notice, text: "Interrupted", date: date))
            return
        }
        s.entries.append(TranscriptEntry(kind: .user, text: text, date: date))
    }

    /// One line about a tool call: the command, file, pattern or URL it works on.
    static func toolSummary(_ name: String, _ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt", "skill", "subject"] {
            if let v = input[key] as? String, !v.isEmpty {
                var line = v.split(whereSeparator: \.isNewline).first.map(String.init) ?? v
                if key == "file_path" || key == "path" { line = (line as NSString).abbreviatingWithTildeInPath }
                return String(line.prefix(200))
            }
        }
        return ""
    }

    /// The first few lines of a tool result (string or text blocks).
    static func resultText(_ content: Any?) -> String {
        var text = ""
        if let s = content as? String { text = s }
        else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if text.isEmpty, parts.contains(where: { $0["type"] as? String == "image" }) { text = "[image]" }
        }
        let lines = text.split(whereSeparator: \.isNewline).prefix(4)
        return String(lines.joined(separator: "\n").prefix(400))
    }

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle()

    static func parseDate(_ s: String) -> Date? { (try? isoFractional.parse(s)) ?? (try? iso.parse(s)) }

    // MARK: - Sessions

    /// A live process's session, its status from the registry and details from the transcript.
    /// `remoteID`: from the process's `--sdk-url`, when it is a `claude rc` child. Without
    /// the command line, a driven (`sdk-cli`) process with a bridge id and no tmux counts too.
    static func session(_ r: Record, summary: Summary?, transcript: URL?, host: String? = nil, remoteID: String? = nil) -> AgentSession {
        let status = AgentStatus.claude(r.status)
        var detail: String?
        if status == .waiting, let tool = summary?.pendingTool { detail = "\(tool) permission" }
        if status == .running, let tool = summary?.pendingTool { detail = tool }
        let title = r.name ?? summary?.title ?? summary?.lastPrompt.map { String($0.prefix(80)) } ?? String(r.sessionID.prefix(8))
        let activity = [r.updatedAt, summary?.lastActivity].compactMap { $0 }.max() ?? r.startedAt ?? .distantPast
        let driven = r.entrypoint == "sdk-cli" && r.tmux == nil && r.bridgeSessionID != nil
        let rc = remoteID ?? (driven ? r.bridgeSessionID.map(infraSessionID) : nil)
        return AgentSession(provider: .claude, id: r.sessionID, host: host, title: title,
                            cwd: r.cwd.isEmpty ? (summary?.cwd ?? "") : r.cwd, status: status, lastActivity: activity,
                            pid: r.pid, tmux: r.tmux, bridgeID: r.bridgeSessionID, transcript: transcript?.path,
                            detail: detail, model: summary?.model, kind: rc == nil ? .terminal : .remoteControl, remoteID: rc)
    }

    /// A finished session from its transcript alone.
    static func finished(_ url: URL, modified: Date, summary: Summary) -> AgentSession {
        let id = url.deletingPathExtension().lastPathComponent
        let title = summary.title ?? summary.lastPrompt.map { String($0.prefix(80)) }
            ?? summary.entries.first { $0.kind == .user }.map { String($0.text.prefix(80)) } ?? String(id.prefix(8))
        return AgentSession(provider: .claude, id: id, host: nil, title: title, cwd: summary.cwd ?? "", status: .finished,
                            lastActivity: summary.lastActivity ?? modified, pid: nil, tmux: nil, bridgeID: nil,
                            transcript: url.path, detail: nil, model: summary.model)
    }
}

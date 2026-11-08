import Darwin
import Foundation

/// The Codex CLI's on-disk state: one JSONL rollout per session in
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` (`session_meta` first, then
/// `turn_context`, `response_item` messages and tool calls, `event_msg` turn events), and
/// thread names in `~/.codex/session_index.jsonl`. Archived sessions move elsewhere and are
/// left out, compressed (`.jsonl.zst`) ones too. Read only.
nonisolated enum CodexSessions {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex") }
    static var sessionsDir: URL { home.appending(path: "sessions") }
    static var indexFile: URL { home.appending(path: "session_index.jsonl") }

    /// What the panel needs from a rollout.
    struct Summary: Equatable, Sendable {
        var entries: [TranscriptEntry] = []
        var cwd: String?
        var model: String?
        var lastActivity: Date?
        var firstPrompt: String?
        var lastPrompt: String?
        /// A turn started and has not completed or been aborted.
        var inTurn = false
        /// A tool call with no output yet.
        var pendingTool: String?
        /// The last turn's error, when it failed.
        var error: String?
    }

    /// The session id in a rollout's file name: the UUID after the timestamp.
    static func sessionID(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-"), fileName.hasSuffix(".jsonl") else { return nil }
        let stem = fileName.dropLast(6)
        guard stem.count > 36 else { return nil }
        let id = String(stem.suffix(36))
        return id.wholeMatch(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) != nil ? id : nil
    }

    /// Parses rollout lines (oldest first). Keeps the last `limit` entries.
    static func parse(_ data: Data, limit: Int = 80) -> Summary {
        var s = Summary()
        var calls: [(id: String, name: String)] = []
        var answered = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = o["type"] as? String, let p = o["payload"] as? [String: Any] else { continue }
            let date = (o["timestamp"] as? String).flatMap(ClaudeSessions.parseDate)
            if let date { s.lastActivity = date }
            switch type {
            case "session_meta", "turn_context":
                if let cwd = p["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
                if let model = p["model"] as? String, !model.isEmpty { s.model = model }
            case "event_msg":
                switch p["type"] as? String {
                case "task_started":
                    s.inTurn = true
                    s.error = nil
                case "task_complete":
                    s.inTurn = false
                    s.error = (p["error"] as? [String: Any])?["message"] as? String
                    if let e = s.error { s.entries.append(TranscriptEntry(kind: .notice, text: String(e.prefix(200)), date: date)) }
                case "turn_aborted":
                    s.inTurn = false
                    s.entries.append(TranscriptEntry(kind: .notice, text: "Interrupted", date: date))
                default: break
                }
            case "response_item":
                switch p["type"] as? String {
                case "message":
                    let role = p["role"] as? String
                    let text = messageText(p["content"])
                    guard !text.isEmpty else { continue }
                    if role == "assistant" {
                        s.entries.append(TranscriptEntry(kind: .assistant, text: text, date: date))
                    } else if role == "user", !isInjected(text) {
                        s.entries.append(TranscriptEntry(kind: .user, text: text, date: date))
                        if s.firstPrompt == nil { s.firstPrompt = text }
                        s.lastPrompt = text
                    }
                case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
                    let (name, summary) = toolCall(p)
                    let id = p["call_id"] as? String ?? p["id"] as? String
                    s.entries.append(TranscriptEntry(kind: .tool(name: name), text: summary, date: date, toolID: id))
                    if let id, p["type"] as? String != "web_search_call" { calls.append((id, name)) }
                case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                    if let id = p["call_id"] as? String { answered.insert(id) }
                    let (text, isError) = toolOutput(p["output"])
                    s.entries.append(TranscriptEntry(kind: .result(isError: isError), text: text, date: date))
                default: break
                }
            default: break
            }
        }
        if s.entries.count > limit { s.entries.removeFirst(s.entries.count - limit) }
        s.pendingTool = s.inTurn ? calls.last.flatMap { answered.contains($0.id) ? nil : $0.name } : nil
        return s
    }

    /// Text parts of a message (`input_text` / `output_text`), trimmed.
    static func messageText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parts = content as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Context Codex adds as user messages (environment, AGENTS.md, app state): not prompts.
    static func isInjected(_ text: String) -> Bool {
        text.hasPrefix("<") || text.hasPrefix("# AGENTS.md instructions")
    }

    /// A tool call's name and one line about it. Codex wraps tools in an `exec` JavaScript
    /// call (`tools.exec_command({cmd: …})`, `tools.apply_patch("*** Add File: …")`); older
    /// versions call `shell` / `exec_command` with JSON arguments.
    static func toolCall(_ p: [String: Any]) -> (name: String, summary: String) {
        var name = p["name"] as? String ?? (p["type"] as? String == "web_search_call" ? "web_search" : "shell")
        var input: [String: Any]?
        if let args = p["arguments"] as? String {
            input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
        } else if let action = p["action"] as? [String: Any] {
            input = action
        }
        if let raw = p["input"] as? String {
            if let m = raw.firstMatch(of: /tools\.([A-Za-z0-9_]+)\(/) { name = String(m.1) }
            if let m = raw.firstMatch(of: /\*\*\* (?:Add|Update|Delete) File: ([^\\\n"]+)/) {
                return (name, (String(m.1) as NSString).abbreviatingWithTildeInPath)
            }
            if let m = raw.firstMatch(of: /"?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)"/) {
                // A JavaScript string literal: JSON's escapes cover it.
                let cmd = (try? JSONDecoder().decode(String.self, from: Data("\"\(m.1)\"".utf8))) ?? String(m.1)
                return (name, String((cmd.split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd).prefix(200)))
            }
            let first = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
            return (name, String(first.prefix(200)))
        }
        guard var input else { return (name, "") }
        if let cmd = input["command"] as? [String] {
            // ["bash", "-lc", "make test"] is the script; anything else reads as one line.
            input["command"] = cmd.count == 3 && cmd[1].hasPrefix("-") ? cmd[2] : cmd.joined(separator: " ")
        }
        if let cmd = input["cmd"] as? String { input["command"] = cmd }
        return (name, ClaudeSessions.toolSummary(name, input))
    }

    /// A tool's output: a string, a JSON string with `output` and an exit code, or text parts.
    static func toolOutput(_ raw: Any?) -> (text: String, isError: Bool) {
        if let s = raw as? String {
            if let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], let out = o["output"] as? String {
                let code = ((o["metadata"] as? [String: Any])?["exit_code"] as? NSNumber)?.intValue ?? 0
                return (ClaudeSessions.resultText(out), code != 0)
            }
            return (ClaudeSessions.resultText(s), false)
        }
        if let parts = raw as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let cleaned = text.replacingOccurrences(of: "Script completed\n", with: "")
                .split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("Wall time") && $0 != "Output:" }.joined(separator: "\n")
            // exec_command answers with JSON: its output and exit code.
            if let o = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] {
                let code = (o["exit_code"] as? NSNumber)?.intValue ?? 0
                return (ClaudeSessions.resultText(o["output"] as? String ?? ""), code != 0)
            }
            return (ClaudeSessions.resultText(cleaned), text.hasPrefix("Script failed") || text.contains("\"exit_code\":1"))
        }
        if let o = raw as? [String: Any], let out = o["output"] as? String { return (ClaudeSessions.resultText(out), false) }
        return ("", false)
    }

    // MARK: - Files

    /// Rollouts changed since `since`, newest first. A file's mtime is never older than its
    /// last line, so this is a superset: callers filter by the parsed last activity.
    static func recentRollouts(since: Date, root: URL = sessionsDir, limit: Int = 60) -> [(url: URL, modified: Date)] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > since else { continue }
            found.append((url, m))
        }
        return Array(found.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// The working directory from the first lines (`session_meta` sits on line one, which can
    /// be long; its `cwd` comes early in it).
    static func headCwd(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let m = text.firstMatch(of: /"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/) else { return nil }
        return String(m.1).replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Thread names by session id (`session_index.jsonl`; later lines win).
    static func threadNames(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String, !name.isEmpty else { continue }
            out[id] = name
        }
        return out
    }

    // MARK: - Sessions

    /// A session from its rollout. `live`: the pid of the `codex` process running it, if any.
    static func session(id: String, url: URL, modified: Date, summary: Summary, title: String?, cwd: String?, live: Int32?) -> AgentSession {
        let title = title ?? summary.firstPrompt.map { String($0.prefix(80)) } ?? String(id.prefix(8))
        var status: AgentStatus = .finished
        var detail: String?
        if live != nil {
            status = summary.inTurn ? .running : .idle
            if status == .running { detail = summary.pendingTool }
        }
        if summary.error != nil, !summary.inTurn { detail = "failed" }
        return AgentSession(provider: .codex, id: id, host: nil, title: title, cwd: summary.cwd ?? cwd ?? "", status: status,
                            lastActivity: summary.lastActivity ?? modified, pid: live, tmux: nil, bridgeID: nil,
                            transcript: url.path, detail: detail, model: summary.model)
    }

    /// Which sessions the running `codex` processes hold: per working directory, the most
    /// recently active ones, one per process.
    static func liveMap(_ sessions: [(id: String, cwd: String, activity: Date)], processes: [(pid: Int32, cwd: String)]) -> [String: Int32] {
        var out: [String: Int32] = [:]
        let byCwd = Dictionary(grouping: processes, by: \.cwd)
        for (cwd, procs) in byCwd {
            let candidates = sessions.filter { $0.cwd == cwd }.sorted { $0.activity > $1.activity }
            for (s, p) in zip(candidates, procs.sorted { $0.pid > $1.pid }) { out[s.id] = p.pid }
        }
        return out
    }
}

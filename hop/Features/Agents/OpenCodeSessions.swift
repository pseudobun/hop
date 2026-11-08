import Darwin
import Foundation
import SQLite3

/// OpenCode (v2) keeps sessions in `~/.local/share/opencode/opencode.db` (SQLite, WAL):
/// `session_v2` rows with busy / idle times, `session_message` rows with JSON bodies.
/// Read only; the background service does not need to run.
nonisolated enum OpenCodeSessions {
    static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/opencode/opencode.db")
    }

    /// One `session_v2` row.
    struct Row: Equatable, Sendable {
        var id: String
        var title: String?
        var slug: String
        var directory: String
        var updated: Int64
        var busy: Int64?
        var idle: Int64?
        var outcome: String?
        var model: String?
    }

    /// Busy after the last idle: working on a turn.
    static func isBusy(_ r: Row) -> Bool {
        guard let busy = r.busy else { return false }
        return r.idle.map { busy > $0 } ?? true
    }

    /// `liveDirectories`: folders an `opencode` process runs in, so a session there is idle, not finished.
    static func session(_ r: Row, liveDirectories: Set<String>, pendingTool: String? = nil) -> AgentSession {
        var status: AgentStatus = isBusy(r) ? .running : (liveDirectories.contains(r.directory) ? .idle : .finished)
        var detail: String?
        if status == .running, let pendingTool {
            status = .waiting
            detail = "\(pendingTool) permission"
        }
        if let o = r.outcome, o != "succeeded", status == .finished || status == .idle { detail = o }
        let model = r.model.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }?["id"] as? String
        let title = (r.title?.isEmpty == false ? r.title : nil) ?? r.slug
        return AgentSession(provider: .opencode, id: r.id, host: nil, title: title, cwd: r.directory, status: status,
                            lastActivity: Date(timeIntervalSince1970: Double(r.updated) / 1000), pid: nil, tmux: nil,
                            bridgeID: nil, transcript: nil, detail: detail, model: model)
    }

    /// Messages (oldest first) as transcript entries, and a tool still waiting to run.
    static func entries(_ messages: [(type: String, data: String)], limit: Int = 80) -> (entries: [TranscriptEntry], pendingTool: String?) {
        var out: [TranscriptEntry] = []
        var pending: String?
        for m in messages {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(m.data.utf8))) as? [String: Any] else { continue }
            let created = ((o["time"] as? [String: Any])?["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            switch m.type {
            case "user":
                let text = (o["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(TranscriptEntry(kind: .user, text: text, date: created)) }
                pending = nil
            case "assistant":
                for part in o["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "text":
                        let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { out.append(TranscriptEntry(kind: .assistant, text: text, date: created)) }
                    case "tool":
                        let name = part["name"] as? String ?? "tool"
                        let state = part["state"] as? [String: Any] ?? [:]
                        let status = state["status"] as? String ?? ""
                        out.append(TranscriptEntry(kind: .tool(name: name),
                                                   text: ClaudeSessions.toolSummary(name, state["input"] as? [String: Any]),
                                                   date: created, toolID: part["id"] as? String))
                        switch status {
                        case "completed":
                            out.append(TranscriptEntry(kind: .result(isError: false), text: ClaudeSessions.resultText(state["content"] ?? state["output"]), date: created))
                            pending = nil
                        case "error", "failed":
                            let err = state["error"] as? String ?? ClaudeSessions.resultText(state["content"])
                            out.append(TranscriptEntry(kind: .result(isError: true), text: String(err.prefix(400)), date: created))
                            pending = nil
                        case "pending":
                            pending = name
                        default:
                            pending = nil
                        }
                    default: break
                    }
                }
            default: break
            }
        }
        if out.count > limit { out.removeFirst(out.count - limit) }
        return (out, pending)
    }

    // MARK: - Reading

    private static let queue = DispatchQueue(label: "hop.agents.opencode", qos: .userInitiated)

    /// Top-level, unarchived sessions updated since `since`, newest first.
    static func sessions(since: Date, path: String = database.path) async -> [Row] {
        await withCheckedContinuation { done in queue.async { done.resume(returning: readSessions(since: since, path: path)) } }
    }

    static func messages(session id: String, path: String = database.path) async -> [(type: String, data: String)] {
        await withCheckedContinuation { done in queue.async { done.resume(returning: readMessages(session: id, path: path)) } }
    }

    static func readSessions(since: Date, path: String) -> [Row] {
        withDatabase(path) { db in
            let sql = """
                SELECT id, title, slug, directory, time_updated, time_busy, time_idle, idle_outcome, model
                FROM session_v2 WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated > ?
                ORDER BY time_updated DESC LIMIT 60
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
            var rows: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Row(id: text(stmt, 0) ?? "", title: text(stmt, 1), slug: text(stmt, 2) ?? "",
                                directory: text(stmt, 3) ?? "", updated: sqlite3_column_int64(stmt, 4),
                                busy: int(stmt, 5), idle: int(stmt, 6), outcome: text(stmt, 7), model: text(stmt, 8)))
            }
            return rows
        } ?? []
    }

    static func readMessages(session id: String, path: String) -> [(type: String, data: String)] {
        withDatabase(path) { db in
            let sql = "SELECT type, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT 120"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            var out: [(String, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append((text(stmt, 0) ?? "", text(stmt, 1) ?? "")) }
            return out.reversed().map { (type: $0.0, data: $0.1) }
        } ?? []
    }

    private static func withDatabase<T>(_ path: String, _ body: (OpaquePointer?) -> T) -> T? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 1000)
        return body(db)
    }

    private static func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }

    private static func int(_ stmt: OpaquePointer?, _ i: Int32) -> Int64? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
    }

    // MARK: - Processes

    /// Working directories of running processes named `name` (the OpenCode TUI runs in its project).
    static func processDirectories(named name: String = "opencode") -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var dirs = Set<String>()
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 else { continue }
            let pname = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard pname == name else { continue }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { dirs.insert(path) }
        }
        return dirs
    }
}

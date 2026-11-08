import Foundation

/// herdr (herdr.dev), a terminal workspace manager that recognizes coding agents in its
/// panes. hop reads its `api snapshot`, starts agents with `workspace create` + `agent
/// start`, attaches with `agent attach` and sends quick prompts with `agent prompt`, all
/// through its CLI (here, or on a host through the ssh script).
///
/// Parsing follows `herdr api schema` for protocol 22 (herdr 0.9.0 and 0.9.5, schema_version
/// 1): `SessionSnapshot.agents[]` are `AgentInfo`, `agent_status` is idle, working, blocked,
/// done or unknown. Unknown fields are ignored; another protocol makes hop leave herdr alone
/// (tmux takes over) and say so in the panel.
nonisolated enum Herdr {
    static let knownProtocol = 22

    /// One `AgentInfo`.
    struct Agent: Equatable, Sendable {
        var paneID: String
        var workspaceID: String
        /// "claude", "opencode", … (herdr's agent kind).
        var agent: String?
        var status: String
        /// The live agent name (`agent start <name>`), unique on that server.
        var name: String?
        var cwd: String?
        var title: String?
        /// `agent_session.value` when its kind is "id": Claude Code's session id.
        var sessionID: String?
        var stateChangeSeq: Int = 0
    }

    struct Snapshot: Equatable, Sendable {
        var version: String
        var proto: Int
        var agents: [Agent]
        /// Workspace labels by id.
        var workspaces: [String: String] = [:]

        var isCompatible: Bool { proto == Herdr.knownProtocol }
    }

    /// `herdr api snapshot` output (`{"result":{"snapshot":{…}}}`) or a bare snapshot.
    static func parseSnapshot(_ data: Data) -> Snapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let result = root["result"] as? [String: Any]
        guard let snap = (result?["snapshot"] as? [String: Any]) ?? (root["agents"] != nil ? root : nil),
              let proto = (snap["protocol"] as? NSNumber)?.intValue else { return nil }
        var workspaces: [String: String] = [:]
        for w in snap["workspaces"] as? [[String: Any]] ?? [] {
            if let id = w["workspace_id"] as? String { workspaces[id] = w["label"] as? String ?? "" }
        }
        let agents = (snap["agents"] as? [[String: Any]] ?? []).compactMap(parseAgent)
        return Snapshot(version: snap["version"] as? String ?? "?", proto: proto, agents: agents, workspaces: workspaces)
    }

    static func parseAgent(_ o: [String: Any]) -> Agent? {
        guard let pane = o["pane_id"] as? String, let ws = o["workspace_id"] as? String else { return nil }
        func text(_ key: String) -> String? { (o[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var session: String?
        if let s = o["agent_session"] as? [String: Any], s["kind"] as? String == "id" { session = s["value"] as? String }
        return Agent(paneID: pane, workspaceID: ws, agent: text("agent"), status: text("agent_status") ?? "unknown", name: text("name"),
                     cwd: text("foreground_cwd") ?? text("cwd"), title: text("terminal_title_stripped") ?? text("title"),
                     sessionID: session, stateChangeSeq: (o["state_change_seq"] as? NSNumber)?.intValue ?? 0)
    }

    /// herdr's lifecycle state as the panel's; nil for "unknown" (keep what else says).
    static func status(_ raw: String) -> AgentStatus? {
        switch raw {
        case "working": .running
        case "blocked": .waiting
        case "idle", "done": .idle
        default: nil
        }
    }

    static func provider(_ agent: String?) -> AgentProvider? {
        switch agent {
        case "claude": .claude
        case "opencode": .opencode
        case "codex": .codex
        case "cursor": .cursor
        default: nil
        }
    }

    /// herdr agent names: `[a-z][a-z0-9_-]{0,31}`. hop's names fit when the folder part is short.
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z][a-z0-9_-]{0,31}/) != nil
    }

    /// Pane ids look like "w1Q:p1".
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_") }
    }

    /// A hop-started agent: named hop-cc-…/hop-oc-… in a workspace hop labelled the same.
    static func isHopOwned(_ a: Agent, snapshot: Snapshot) -> Bool {
        guard let name = a.name, AgentNames.provider(ofTmux: name) != nil else { return false }
        return snapshot.workspaces[a.workspaceID] == name
    }

    // MARK: - Merging into the session list

    /// Adds herdr's view to the sessions: a Claude session herdr hosts (same session id) gets
    /// its pane and herdr's status; other agents become rows of their own.
    static func merge(_ snapshot: Snapshot, into sessions: [AgentSession], host: String?,
                      transcript: (String, String) -> String? = { _, _ in nil }) -> [AgentSession] {
        guard snapshot.isCompatible else { return sessions }
        var out = sessions
        for a in snapshot.agents {
            guard let provider = provider(a.agent) else { continue }
            let owned = isHopOwned(a, snapshot: snapshot)
            var index: Int?
            if let id = a.sessionID { index = out.firstIndex { $0.provider == provider && $0.id == id && $0.host == host } }
            // Agents without a session id herdr knows: matched by folder.
            if index == nil, provider != .claude, let cwd = a.cwd {
                index = out.firstIndex { $0.provider == provider && $0.host == host && $0.cwd == cwd && $0.status != .finished && $0.herdrPane == nil
                    && $0.tmux == nil }
            }
            if let i = index {
                out[i].herdrPane = a.paneID
                out[i].herdrName = a.name
                out[i].herdrWorkspace = owned ? a.workspaceID : nil
                out[i].kind = .terminal
                if let st = status(a.status) {
                    if out[i].status == .finished { out[i].detail = nil }
                    out[i].status = st
                } else if out[i].status == .finished {
                    out[i].status = .running
                }
                if out[i].status != .waiting && out[i].detail?.hasSuffix("permission") == true { out[i].detail = nil }
                continue
            }
            let id = a.sessionID ?? "herdr:\(a.paneID)"
            let path = a.sessionID.flatMap { transcript($0, a.cwd ?? "") }
            let activity = path.flatMap { AgentStore.FileStamp.of($0)?.modified } ?? .distantPast
            out.append(AgentSession(provider: provider, id: id, host: host, title: a.name ?? a.title ?? snapshot.workspaces[a.workspaceID] ?? a.paneID,
                                    cwd: a.cwd ?? "", status: status(a.status) ?? .running, lastActivity: activity, pid: nil, tmux: nil,
                                    bridgeID: nil, transcript: path, detail: nil, model: nil, kind: .terminal, remoteID: nil,
                                    herdrPane: a.paneID, herdrName: a.name, herdrWorkspace: owned ? a.workspaceID : nil))
        }
        return out
    }

    // MARK: - Commands

    /// Bash for a host's listing script: the snapshot on one line ("H\t…"), and "Q|herdr:<name>"
    /// for hop's Claude agents that show the folder trust question.
    static func remoteListLines(herdr: String) -> String {
        let h = AgentCommands.quote(herdr)
        return """
            if command -v \(h) >/dev/null 2>&1; then
              hs=$(\(h) api snapshot 2>/dev/null | tr -d '\\n')
              if [ -n "$hs" ]; then
                printf 'H\\t%s\\n' "$hs"
                printf '%s' "$hs" | grep -o '"name":"hop-cc-[a-z0-9_-]*"' | cut -d'"' -f4 | while read -r n; do
                  \(h) agent read "$n" --source visible 2>/dev/null | grep -q '\(ClaudeTrust.yesOption)' && printf 'Q|herdr:%s\\n' "$n"
                done
              fi
            fi
            """
    }

    /// Bash that starts an agent in a new herdr workspace labelled like the agent, or in tmux
    /// when herdr is missing, unreachable or speaks another protocol (it prints "fallback: why").
    /// `cd` to the folder comes first; `tmuxFallback` is the tmux command line.
    static func spawnScript(herdr: String, name: String, kind: String, agentArgs: [String], tmuxFallback: String) -> String {
        let h = AgentCommands.quote(herdr)
        let n = AgentCommands.quote(name)
        let args = agentArgs.map(AgentCommands.quote).joined(separator: " ")
        return """
            why=""
            if ! command -v \(h) >/dev/null 2>&1; then why="herdr is not installed"
            else
              proto=$(\(h) api snapshot 2>/dev/null | grep -o '"protocol": *[0-9]*' | head -1 | grep -o '[0-9]*$')
              if [ -z "$proto" ]; then why="the herdr server is not running"
              elif [ "$proto" != \(knownProtocol) ]; then why="herdr speaks protocol $proto, hop knows \(knownProtocol)"
              fi
            fi
            if [ -n "$why" ]; then
              echo "fallback: $why"
              command -v tmux >/dev/null 2>&1 || { echo "$why, and tmux is not installed" >&2; exit 4; }
              \(tmuxFallback)
              exit $?
            fi
            ws=$(\(h) workspace create --cwd "$PWD" --label \(n) --no-focus 2>&1) || { echo "$ws" >&2; exit 6; }
            pane=$(printf '%s' "$ws" | grep -o '"pane_id":"[^"]*"' | head -1 | cut -d'"' -f4)
            [ -n "$pane" ] || { echo "herdr did not say which pane it made" >&2; exit 6; }
            out=$(\(h) agent start \(n) --kind \(AgentCommands.quote(kind)) --pane "$pane" --timeout 20000 -- \(args) 2>&1) && exit 0
            case "$out" in *agent_not_ready*) exit 0 ;; esac
            echo "$out" | tr -d '\\n' >&2; echo >&2
            exit 7
            """
    }

    /// The agent's own arguments for `herdr agent start … --`: what `agentArguments` gives,
    /// without the binary (herdr starts its own kind of agent).
    static func agentStartArguments(_ agent: [String]) -> [String] { Array(agent.dropFirst()) }

    /// Bash that sends one prompt line to a herdr agent.
    static func promptScript(herdr: String, pane: String, text: String) -> String {
        "\(AgentCommands.quote(herdr)) agent prompt \(AgentCommands.quote(pane)) \(AgentCommands.quote(text))"
    }

    /// A herdr error's message (`{"error":{"code":…,"message":…}}`), else the last line.
    static func errorMessage(_ text: String) -> String {
        if let start = text.firstIndex(of: "{"),
           let o = (try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))) as? [String: Any],
           let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

    /// The `workspace create` reply's root pane.
    static func rootPane(_ data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = o["result"] as? [String: Any], let pane = r["root_pane"] as? [String: Any] else { return nil }
        return pane["pane_id"] as? String
    }
}

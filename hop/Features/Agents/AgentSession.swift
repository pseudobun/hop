import Foundation

/// Coding agents the panel knows about.
nonisolated enum AgentProvider: String, CaseIterable, Sendable, Codable {
    case claude, opencode

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        }
    }

    /// Short tag in tmux session names hop creates: hop-cc-…, hop-oc-….
    var tag: String {
        switch self {
        case .claude: "cc"
        case .opencode: "oc"
        }
    }
}

/// How a session runs, which decides what hop can do with it.
nonisolated enum AgentKind: String, Sendable {
    /// A terminal session (in tmux or not).
    case terminal
    /// A headless child of `claude rc` (Remote Control server mode): no terminal to attach,
    /// continued in the Claude app or on claude.ai/code.
    case remoteControl
}

/// What a session is doing, in the order the panel lists them.
nonisolated enum AgentStatus: Int, Comparable, Sendable {
    /// Waiting for you: a permission prompt or a question.
    case waiting
    /// Working on a turn.
    case running
    /// Open, done with its turn, waiting for the next prompt.
    case idle
    /// The process is gone; the transcript is still there.
    case finished

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .waiting: "Needs you"
        case .running: "Running"
        case .idle: "Idle"
        case .finished: "Finished"
        }
    }

    /// Claude Code's `~/.claude/sessions/<pid>.json` status: busy, shell, idle or waiting.
    static func claude(_ raw: String?) -> AgentStatus {
        switch raw {
        case "busy", "shell": .running
        case "waiting": .waiting
        default: .idle
        }
    }
}

/// One line of a transcript, as the panel shows it.
nonisolated struct TranscriptEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user
        case assistant
        /// A tool call: `name` and a one-line summary of its input in `text`.
        case tool(name: String)
        /// What a tool returned (first lines only).
        case result(isError: Bool)
        /// Interruptions, compaction and other notices.
        case notice
    }

    var kind: Kind
    var text: String
    var date: Date?
    /// Tool calls: the id their result refers to.
    var toolID: String?
}

/// An agent session: live (a process or tmux session) or recently finished.
nonisolated struct AgentSession: Equatable, Sendable {
    var provider: AgentProvider
    /// Session id (Claude's UUID, OpenCode's ses_…); tmux-only rows use "tmux:<name>".
    var id: String
    /// Remote host label (`agents.hosts[].name`); nil on this Mac.
    var host: String?
    var title: String
    var cwd: String
    var status: AgentStatus
    var lastActivity: Date
    var pid: Int32?
    /// The tmux session the agent runs in, when it does.
    var tmux: String?
    /// Claude Code remote-control session ("session_…"), open on claude.ai/code.
    var bridgeID: String?
    /// Local transcript (Claude JSONL); nil for OpenCode and remote sessions.
    var transcript: String?
    /// Short extra detail for the status: "Bash permission", "failed".
    var detail: String?
    var model: String?
    var kind: AgentKind = .terminal
    /// The claude.ai session a Remote Control child serves ("cse_…").
    var remoteID: String? = nil
    /// Claude Code waits on its folder trust question in this hop tmux session.
    var needsTrust = false

    /// Stable across refreshes, for keeping the selection.
    var key: String { "\(host ?? "local")/\(provider.rawValue)/\(id)" }

    var isLocal: Bool { host == nil }

    /// `~/repos/hop`, or the remote path as given.
    var shortCwd: String {
        isLocal ? (cwd as NSString).abbreviatingWithTildeInPath : cwd
    }

    /// claude.ai/code/session_<id> for remote-control sessions. Claude Code builds the same
    /// link: `/code/` plus the id with a "cse_" prefix turned into "session_".
    var webURL: URL? {
        let id = bridgeID.flatMap { $0.isEmpty ? nil : $0 } ?? remoteID.map(ClaudeSessions.compatSessionID)
        guard let id, !id.isEmpty else { return nil }
        return URL(string: "https://claude.ai/code/\(id)")
    }

    /// A terminal can attach to it: it runs in tmux.
    var isAttachable: Bool { tmux != nil }

    /// Live but not in tmux (a `claude rc` child, or a terminal hop cannot reach): watch only.
    var isViewOnly: Bool { status != .finished && tmux == nil }

    /// Short row tag for how it can be reached: "tmux" (attach), "rc" (view only, open in
    /// Claude), "view only"; nil once finished. The detail header spells it out.
    var accessTag: String? {
        if isAttachable { return "tmux" }
        guard isViewOnly else { return nil }
        return kind == .remoteControl ? "rc" : "view only"
    }

    /// Marks the sessions whose tmux session shows Claude Code's trust question: they need you.
    static func markTrustPrompts(_ sessions: [AgentSession], prompts: Set<String>) -> [AgentSession] {
        guard !prompts.isEmpty else { return sessions }
        return sessions.map { s in
            guard s.provider == .claude, s.status != .finished, let t = s.tmux, prompts.contains(t) else { return s }
            var s = s
            s.needsTrust = true
            s.status = .waiting
            s.detail = "trust folder"
            return s
        }
    }

    /// Waiting first, then running, idle and finished; newest first within each.
    static func ordered(_ a: AgentSession, _ b: AgentSession) -> Bool {
        if a.status != b.status { return a.status < b.status }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.key < b.key
    }
}

/// A pane of a tmux session (`tmux list-panes -a`).
nonisolated struct TmuxPane: Equatable, Sendable {
    var session: String
    var pid: Int32
    var created: Date?
    var path: String

    /// tmux prints control characters (tabs too) as "_", so fields are split on "|"; the path,
    /// which could hold one, comes last.
    static let format = "#{session_name}|#{pane_pid}|#{session_created}|#{pane_current_path}"

    /// Parses `list-panes -F format` output; lines may carry a "T|" prefix (remote script).
    static func parse(_ text: String) -> [TmuxPane] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "T" { parts.removeFirst() }
            guard parts.count >= 4, let pid = Int32(parts[1]) else { return nil }
            return TmuxPane(session: parts[0], pid: pid, created: Double(parts[2]).map { Date(timeIntervalSince1970: $0) },
                            path: parts[3...].joined(separator: "|"))
        }
    }
}

/// tmux session names hop gives the agents it starts.
nonisolated enum AgentNames {
    /// `hop-cc-hop-3f2a`: provider tag, folder name (letters, digits, dashes) and 4 hex.
    static func tmuxName(provider: AgentProvider, cwd: String, suffix: String) -> String {
        let base = (cwd as NSString).lastPathComponent.lowercased()
        var slug = String(base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "home" }
        return "hop-\(provider.tag)-\(String(slug.prefix(24)))-\(suffix)"
    }

    static func randomSuffix() -> String { String(format: "%04x", UInt16.random(in: 0...UInt16.max)) }

    /// The provider of a tmux session hop started, from its name.
    static func provider(ofTmux name: String) -> AgentProvider? {
        if name.hasPrefix("hop-cc-") { return .claude }
        if name.hasPrefix("hop-oc-") { return .opencode }
        return nil
    }

    /// Short relative age: "now", "4m", "3h", "2d".
    static func age(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int((s / 60).rounded()))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

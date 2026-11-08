import Foundation

/// What a chat runs on: `ChatEngine` today, another backend (a T3 Code server client) later.
/// The panel only talks to this.
protocol ChatBackend: AnyObject {
    var state: ChatState { get }
    /// Called on the main actor after any change of `state`.
    var onChange: (() -> Void)? { get set }
    func send(_ text: String)
    func interrupt()
    func respond(approval id: String, decision: ChatDecision)
    /// Ends the agent.
    func stop()
    /// hop quits: let go without ending the agent where the backend allows it.
    func detach()
}

extension ChatBackend {
    var sessionID: String? { state.sessionID }
    var status: ChatStatus { state.status }
    var items: [ChatItem] { state.items }
    var pendingApprovals: [ChatApproval] { state.pendingApprovals }
    var lastError: String? { state.lastError }
}

extension ChatEngine: ChatBackend {
    /// A child process cannot outlive hop's pipes: detaching ends it.
    func detach() { stop() }
}


/// A chat hop drives itself, listed with the observed sessions. It lives while hop runs,
/// whether or not the panel is open.
final class ChatSession {
    /// "chat:<uuid>": the row's id; the agent's own id is `backend.sessionID`.
    let id: String
    let provider: AgentProvider
    let cwd: String
    let host: HopConfig.Agents.Host?
    /// The first prompt, one line.
    var title: String
    /// The session this chat continues (Continue in Chat), when it does.
    let resumed: String?
    var mode: AgentPermissionMode
    /// The conversation before this chat (from its transcript), shown dimmed above it.
    var history: [TranscriptEntry] = []
    let backend: ChatBackend
    let started = Date()
    var lastActivity = Date()
    /// The status the list last showed: a change reloads the list.
    fileprivate var listed: AgentStatus?
    fileprivate var lastStatus: ChatStatus = .starting

    init(id: String = "chat:" + UUID().uuidString.lowercased(), provider: AgentProvider, cwd: String,
         host: HopConfig.Agents.Host?, title: String, resumed: String?, mode: AgentPermissionMode, backend: ChatBackend) {
        self.id = id
        self.provider = provider
        self.cwd = cwd
        self.host = host
        self.title = title
        self.resumed = resumed
        self.mode = mode
        self.backend = backend
    }

    /// Its row in the list.
    var row: AgentSession {
        ChatRows.session(id: id, provider: provider, host: host?.label, title: title, cwd: cwd, state: backend.state,
                         lastActivity: lastActivity)
    }

    var key: String { row.key }

    /// Agent session ids this chat stands for: an observed session with one of them is the same session.
    var sessionIDs: Set<String> { Set([backend.sessionID, resumed].compactMap { $0 }) }
}

/// The chats hop runs: starts them and tells the panel when they change.
final class ChatSessions {
    private(set) var all: [ChatSession] = []
    /// After any change of a chat; `listChanged` when its row (status, title) moved on.
    var onChange: ((ChatSession, _ listChanged: Bool) -> Void)?
    /// A chat started waiting on an approval.
    var onAttention: ((ChatSession) -> Void)?

    func chat(id: String) -> ChatSession? { all.first { $0.id == id } }

    func chat(key: String) -> ChatSession? { all.first { $0.key == key } }

    /// Starts a chat on `ChatEngine` (Claude Code headless, Codex app-server); `prompt` (when
    /// not empty) is its first message.
    @discardableResult
    func start(provider: ChatProvider, cwd: String, host: HopConfig.Agents.Host?, mode: AgentPermissionMode,
               resume: String? = nil, title: String? = nil, prompt: String = "", config: @escaping () -> HopConfig.Agents) -> ChatSession {
        let agent = ChatRows.agentProvider(provider)
        let c = config()
        let model = ChatRows.model(c.args(agent))
        let title = ChatRows.title(prompt: prompt, fallback: title ?? "New chat in \((cwd as NSString).lastPathComponent)")
        let engine = ChatEngine()
        let chat = add(ChatSession(provider: agent, cwd: cwd, host: host, title: title, resumed: resume, mode: mode, backend: engine))
        let chatHost = host.map { ChatHost(ssh: $0.ssh, binary: $0.binary(for: agent), name: $0.label) }
        let binary = c.binary(agent)
        engine.start(provider: provider, cwd: cwd, host: chatHost, permissionMode: ChatRows.permissionMode(mode), resume: resume,
                     model: model, binary: binary.isEmpty ? nil : binary)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { engine.send(text) }
        return chat
    }

    @discardableResult
    private func add(_ chat: ChatSession) -> ChatSession {
        all.append(chat)
        chat.backend.onChange = { [weak self, weak chat] in
            guard let self, let chat else { return }
            changed(chat)
        }
        return chat
    }

    /// Ends the chat's agent; the chat stays listed as finished.
    func stop(_ chat: ChatSession) { chat.backend.stop() }

    /// Ends it and drops it from the list.
    func remove(_ chat: ChatSession) {
        chat.backend.onChange = nil
        if chat.backend.status != .ended && chat.backend.status != .failed { chat.backend.stop() }
        all.removeAll { $0 === chat }
        onChange?(chat, true)
    }

    /// History loaded later, or another change made outside the backend.
    func touch(_ chat: ChatSession) { onChange?(chat, true) }

    /// hop quits: the agents end (or are let go, where the backend keeps them).
    func detachAll() { for c in all { c.backend.detach() } }

    private func changed(_ chat: ChatSession) {
        chat.lastActivity = Date()
        if chat.title.hasPrefix("New chat in "), let first = chat.backend.items.first(where: { $0.kind == .user }) {
            chat.title = ChatRows.title(prompt: first.text, fallback: chat.title)
        }
        let status = chat.backend.status
        if status == .waitingForApproval, chat.lastStatus != .waitingForApproval { onAttention?(chat) }
        chat.lastStatus = status
        let row = chat.row
        let moved = chat.listed != row.status
        chat.listed = row.status
        onChange?(chat, moved)
    }
}

/// The pure parts: how a chat shows in the list, and what the form's choices map to.
nonisolated enum ChatRows {
    /// List section: needs you, running (starting too), idle, finished (ended or failed).
    static func status(_ s: ChatStatus) -> AgentStatus {
        switch s {
        case .waitingForApproval: .waiting
        case .starting, .running: .running
        case .idle: .idle
        case .ended, .failed: .finished
        }
    }

    /// The row's status detail: what waits on you, what runs, why it failed.
    static func detail(_ state: ChatState) -> String? {
        switch state.status {
        case .waitingForApproval:
            return state.pendingApprovals.first.map { "\($0.title) approval" } ?? "approval"
        case .starting: return "starting"
        case .running:
            return state.items.last { $0.status == .running && ($0.kind == .tool || $0.kind == .fileChange) }?.name
        case .failed: return "failed"
        case .idle, .ended: return nil
        }
    }

    static func session(id: String, provider: AgentProvider, host: String?, title: String, cwd: String, state: ChatState,
                        lastActivity: Date) -> AgentSession {
        AgentSession(provider: provider, id: id, host: host, title: title, cwd: cwd, status: status(state.status),
                     lastActivity: lastActivity, pid: nil, tmux: nil, bridgeID: nil, transcript: nil, detail: detail(state),
                     model: state.model, kind: .chat)
    }

    /// Chats first in their section, observed sessions the chats stand for left out (a Claude
    /// chat writes a transcript, a Codex one a rollout), all in list order.
    static func merge(chats: [(row: AgentSession, ids: Set<String>)], observed: [AgentSession]) -> [AgentSession] {
        let shadowed = Set(chats.flatMap { c in c.ids.map { "\(c.row.host ?? "local")/\(c.row.provider.rawValue)/\($0)" } })
        let rest = observed.filter { !shadowed.contains($0.key) }
        return (chats.map(\.row) + rest).sorted(by: AgentSession.ordered)
    }

    /// The form's mode for a chat, one to one.
    static func permissionMode(_ m: AgentPermissionMode) -> ChatPermissionMode {
        switch m {
        case .supervised: .ask
        case .acceptEdits: .acceptEdits
        case .auto: .auto
        case .full: .bypass
        }
    }

    static func chatProvider(_ p: AgentProvider) -> ChatProvider? {
        switch p {
        case .claude: .claude
        case .codex: .codex
        case .opencode, .cursor: nil
        }
    }

    static func agentProvider(_ p: ChatProvider) -> AgentProvider {
        switch p {
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// Continue in Chat: a Claude Code or Codex session that is idle or finished and not in a
    /// terminal hop reaches (tmux, herdr), nor a chat already.
    static func canContinue(_ s: AgentSession) -> Bool {
        chatProvider(s.provider) != nil && s.kind != .chat && (s.status == .idle || s.status == .finished)
            && s.tmux == nil && s.herdrPane == nil && !s.id.hasPrefix("tmux:") && !s.id.hasPrefix("herdr:")
            && (s.isLocal || s.provider == .claude)
    }

    /// A row title from the first prompt: its first line, at most 80 characters.
    static func title(prompt: String, fallback: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return fallback }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// `--model x`, `--model=x` or `-m x` in the configured flags.
    static func model(_ args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a.hasPrefix("--model=") { return String(a.dropFirst(8)) }
            if a == "--model" || a == "-m", i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    /// The tail of an earlier transcript worth showing above a continued chat.
    static func history(_ entries: [TranscriptEntry], limit: Int = 80) -> [TranscriptEntry] {
        Array(entries.suffix(limit))
    }
}

extension AgentLauncher {
    /// A new git worktree of the spawn's folder, here or on the host; its path.
    static func makeWorktree(_ spawn: AgentCommands.Spawn, host: HopConfig.Agents.Host?,
                             config: HopConfig.Agents) async -> Result<String, Failure> {
        guard let host else { return await makeLocalWorktree(spawn, config: config) }
        let script = AgentCommands.remoteCdLine(spawn) + "\n" + AgentCommands.worktreePrefix(spawn, config: config) + "pwd\n"
        guard let r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: Data(script.utf8),
                                                   timeout: .seconds(30))
        else { return .failure(Failure(text: "ssh could not start")) }
        let last = r.out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard r.ok, last.hasPrefix("/") else {
            return .failure(Failure(text: r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "git worktree failed (\(r.status))"))
        }
        return .success(last)
    }
}

extension ChatRows {
    /// A transcript as chat rows: tool results become their call's output and status; the
    /// last call is still running while the session is.
    nonisolated static func items(_ entries: [TranscriptEntry], running: Bool) -> [ChatItem] {
        var out: [ChatItem] = []
        var open: Int?
        for (i, e) in entries.enumerated() {
            let id = "t\(i)"
            switch e.kind {
            case .user: out.append(ChatItem(id: id, kind: .user, text: e.text)); open = nil
            case .assistant: out.append(ChatItem(id: id, kind: .assistant, text: e.text)); open = nil
            case .notice: out.append(ChatItem(id: id, kind: .notice, text: e.text))
            case .tool(let name):
                if let diff = e.diff {
                    out.append(ChatItem(id: id, kind: .fileChange, text: e.text, name: name, status: .running, path: e.text, diff: diff))
                } else {
                    out.append(ChatItem(id: id, kind: .tool, text: e.text, name: name, status: .running))
                }
                open = out.count - 1
            case .result(let isError):
                guard let j = open else { continue }
                out[j].status = isError ? .failed : .done
                if !e.text.isEmpty, out[j].kind == .tool { out[j].output = ChatState.excerpt(e.text) }
                open = nil
            }
        }
        // Calls without a result: done once the session moved on.
        for j in out.indices where out[j].status == .running && (!running || j != open) { out[j].status = .done }
        return out
    }
}

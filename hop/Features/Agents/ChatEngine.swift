import Foundation

// MARK: - Model

/// Agents hop can drive itself (their own CLI as a child process, over stdio).
nonisolated enum ChatProvider: String, CaseIterable, Sendable, Codable {
    /// `claude -p --input-format stream-json --output-format stream-json`.
    case claude
    /// `codex app-server` (JSON-RPC).
    case codex

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The command name looked up on PATH.
    var command: String { rawValue }
}

/// How much the agent may do without asking, mapped onto each CLI's own settings: T3 Code's
/// four (Supervised, Auto-accept edits, Auto, Full access), plus Plan.
nonisolated enum ChatPermissionMode: String, CaseIterable, Sendable, Codable {
    /// Ask before edits and commands. Claude `default`; Codex `untrusted` + workspace-write.
    case ask
    /// Edits go ahead, commands ask. Claude `acceptEdits`; Codex `on-request` + workspace-write.
    case acceptEdits
    /// A reviewer decides. Claude `auto` (its classifier); Codex `on-request` + workspace-write
    /// with `approvalsReviewer: auto_review`.
    case auto
    /// Read and plan only. Claude `plan`; Codex `on-request` + read-only.
    case plan
    /// Never ask. Claude `bypassPermissions`; Codex `never` + danger-full-access.
    case bypass

    var label: String {
        switch self {
        case .ask: "Supervised"
        case .acceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .plan: "Plan"
        case .bypass: "Full access"
        }
    }
}

/// What the chat session is doing.
nonisolated enum ChatStatus: String, Equatable, Sendable {
    /// The process is starting (or the thread is being created).
    case starting
    /// Working on a turn.
    case running
    /// A turn waits on an approval (`ChatState.pendingApprovals`).
    case waitingForApproval
    /// Ready for the next message.
    case idle
    /// The agent could not start or died; `ChatState.lastError` says why.
    case failed
    /// The process is gone after `stop()` or a clean exit.
    case ended

    var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .waitingForApproval: "Needs you"
        case .idle: "Idle"
        case .failed: "Failed"
        case .ended: "Ended"
        }
    }
}

/// An answer to an approval request.
nonisolated enum ChatDecision: String, Equatable, Sendable, CaseIterable {
    case allow
    /// Allow, and don't ask again for the same thing this session.
    case allowAlways
    case deny

    var label: String {
        switch self {
        case .allow: "Allow"
        case .allowAlways: "Always allow"
        case .deny: "Deny"
        }
    }
}

/// The agent asks before it runs a tool, a command or a file change.
nonisolated struct ChatApproval: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// A Claude Code tool (`toolName`).
        case tool
        /// A shell command (Codex).
        case command
        /// File edits (Codex patch).
        case fileChange
    }

    enum State: String, Equatable, Sendable {
        case pending, allowed, denied
        /// Withdrawn by the agent (turn interrupted) before an answer.
        case cancelled
    }

    /// Request id: what `ChatEngine.respond(approval:…)` takes.
    var id: String
    var kind: Kind
    /// "Bash", "Write", "Run command", "Edit files".
    var title: String
    /// The command, the file, or the agent's own description.
    var detail: String
    /// The agent's reason, when it gave one.
    var reason: String?
    var options: [ChatDecision]
    var state: State = .pending
    /// The tool call / item this is about (Claude tool_use id, Codex item id).
    var itemID: String?
    var toolName: String?
}

/// One row of the chat.
nonisolated struct ChatItem: Equatable, Sendable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        case user, assistant, tool, fileChange, approval, notice, error
    }

    enum Status: String, Equatable, Sendable {
        case running, done, failed, declined
    }

    var id: String
    var kind: Kind
    /// Message text; a tool's one-line summary; notice / error text; approval detail.
    var text: String
    /// Tool name ("Bash", "Shell", "mcp: server.tool").
    var name: String? = nil
    var status: Status = .done
    /// First lines of a tool's output.
    var output: String? = nil
    /// File changes: the (first) path and a unified-ish diff.
    var path: String? = nil
    var diff: String? = nil
    var approval: ChatApproval? = nil
    /// Assistant text still growing with deltas.
    var streaming = false

    /// The same row as the observe-only transcript view shows it.
    var transcriptEntry: TranscriptEntry {
        switch kind {
        case .user: TranscriptEntry(kind: .user, text: text, date: nil)
        case .assistant: TranscriptEntry(kind: .assistant, text: text, date: nil)
        case .tool: TranscriptEntry(kind: .tool(name: name ?? "Tool"), text: text, date: nil, toolID: id)
        case .fileChange: TranscriptEntry(kind: .tool(name: name ?? "Edit"), text: path ?? text, date: nil, toolID: id)
        case .approval, .notice: TranscriptEntry(kind: .notice, text: text, date: nil)
        case .error: TranscriptEntry(kind: .result(isError: true), text: text, date: nil)
        }
    }
}

/// Everything the UI shows for one chat; drivers update it from protocol lines.
nonisolated struct ChatState: Equatable, Sendable {
    var sessionID: String?
    var model: String?
    var items: [ChatItem] = []
    /// What the session does, before pending approvals are taken into account.
    var phase: ChatStatus = .starting
    var lastError: String?

    var status: ChatStatus {
        if phase == .running || phase == .idle, !pendingApprovals.isEmpty { return .waitingForApproval }
        return phase
    }

    var pendingApprovals: [ChatApproval] {
        items.compactMap { $0.approval?.state == .pending ? $0.approval : nil }
    }

    func index(_ id: String) -> Int? { items.lastIndex { $0.id == id } }

    func item(_ id: String) -> ChatItem? { index(id).map { items[$0] } }

    /// Replaces the item with the same id, or appends it.
    mutating func upsert(_ item: ChatItem) {
        if let i = index(item.id) { items[i] = item } else { items.append(item) }
    }

    mutating func update(_ id: String, _ change: (inout ChatItem) -> Void) {
        guard let i = index(id) else { return }
        change(&items[i])
    }

    /// Appends a delta to an item, creating it when it is new.
    mutating func append(_ delta: String, to id: String, kind: ChatItem.Kind = .assistant) {
        if let i = index(id) {
            items[i].text += delta
        } else {
            items.append(ChatItem(id: id, kind: kind, text: delta, streaming: true))
        }
    }

    mutating func notice(_ text: String) {
        items.append(ChatItem(id: "notice-\(items.count)-\(UUID().uuidString.prefix(6))", kind: .notice, text: text))
    }

    mutating func error(_ text: String) {
        lastError = text
        items.append(ChatItem(id: "error-\(items.count)-\(UUID().uuidString.prefix(6))", kind: .error, text: text))
    }

    mutating func addApproval(_ a: ChatApproval) {
        upsert(ChatItem(id: "approval:" + a.id, kind: .approval, text: a.detail, name: a.title, status: .running, approval: a))
    }

    mutating func resolveApproval(_ id: String, _ state: ChatApproval.State) {
        update("approval:" + id) {
            $0.approval?.state = state
            $0.status = state == .allowed ? .done : .declined
        }
    }

    /// Pending approvals the agent dropped (interrupt, turn end) become cancelled.
    mutating func cancelPendingApprovals() {
        for a in pendingApprovals { resolveApproval(a.id, .cancelled) }
    }

    /// Streaming assistant rows are done.
    mutating func endStreaming() {
        for i in items.indices where items[i].streaming { items[i].streaming = false }
    }

    /// Output excerpt: the last `lines` lines, at most `chars` characters.
    static func excerpt(_ text: String, lines: Int = 12, chars: Int = 1500) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var s = all.suffix(lines).joined(separator: "\n")
        if s.count > chars { s = "…" + s.suffix(chars) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Drivers

/// What a driver needs to start its agent.
nonisolated struct ChatOptions: Equatable, Sendable {
    var cwd: String
    var permissionMode: ChatPermissionMode = .ask
    /// Session (Claude) or thread (Codex) to continue.
    var resume: String?
    var model: String?
}

/// Speaks one agent's protocol: what to write, and how output lines change the state.
nonisolated protocol ChatDriver: Sendable {
    /// The agent's arguments after the binary.
    func arguments() -> [String]
    /// Lines to write once the process runs.
    mutating func startLines() -> [String]
    /// Lines that send a user message (the driver may queue it until the agent is ready).
    mutating func sendLines(_ text: String, state: inout ChatState) -> [String]
    mutating func interruptLines(state: inout ChatState) -> [String]
    /// The answer to an approval; marks it in `state`.
    mutating func approvalLines(_ id: String, decision: ChatDecision, state: inout ChatState) -> [String]
    /// Applies one output line; returns lines to write back (automatic replies).
    mutating func handle(_ line: String, state: inout ChatState) -> [String]
}

/// JSON helpers shared by the drivers.
nonisolated enum ChatJSON {
    /// One compact line, keys sorted (stable for tests).
    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Any JSON value as text (for keeping raw payloads in Sendable state).
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func value(_ text: String?) -> Any? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// An error message that may itself be a JSON error body: its innermost "message".
    static func message(_ raw: String) -> String {
        var text = raw
        for _ in 0..<3 {
            guard let o = object(text) else { break }
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String { text = m; continue }
            if let m = o["message"] as? String { text = m; continue }
            break
        }
        return text
    }
}

// MARK: - Engine

/// Drives one agent session and keeps a chat of it: the API the panel uses.
///
///     let chat = ChatEngine()
///     chat.onChange = { … read chat.status / chat.items … }
///     chat.start(provider: .claude, cwd: "~/repos/hop", host: nil, permissionMode: .ask)
///     chat.send("fix the failing test")
///     chat.respond(approval: chat.pendingApprovals[0].id, allow: true)
final class ChatEngine {
    private(set) var state = ChatState()
    private(set) var provider: ChatProvider?
    private(set) var host: ChatHost?
    /// Called on the main actor after any change of `state`.
    var onChange: (() -> Void)?

    var sessionID: String? { state.sessionID }
    var status: ChatStatus { state.status }
    var items: [ChatItem] { state.items }
    var pendingApprovals: [ChatApproval] { state.pendingApprovals }
    var lastError: String? { state.lastError }

    private var driver: (any ChatDriver)?
    private var transport: ChatTransport?
    /// Lines written before the transport is up.
    private var queued: [String] = []
    private var stopping = false
    private var startTask: Task<Void, Never>?

    init() {}

    /// Starts the agent. Returns at once; `status` goes from `.starting` to `.idle` (or
    /// `.failed`). `binary` overrides the agent command (a path here, a name on the host).
    func start(provider: ChatProvider, cwd: String, host: ChatHost? = nil, permissionMode: ChatPermissionMode = .ask,
               resume: String? = nil, model: String? = nil, binary: String? = nil) {
        stop()
        stopping = false
        self.provider = provider
        self.host = host
        state = ChatState()
        state.sessionID = resume
        let options = ChatOptions(cwd: cwd, permissionMode: permissionMode, resume: resume, model: model)
        var driver: any ChatDriver = switch provider {
        case .claude: ChatClaude(options: options)
        case .codex: ChatCodex(options: options)
        }
        queued = driver.startLines()
        self.driver = driver
        let arguments = driver.arguments()
        changed()

        startTask = Task { [weak self] in
            let launch: ChatLaunch
            if let host {
                let command = [host.binary.isEmpty ? (binary ?? provider.command) : host.binary] + arguments
                launch = .remote(ssh: host.ssh, command: command, cwd: cwd)
            } else {
                let path = await AgentTools.loginPath()
                guard let exe = Self.localBinary(provider, override: binary, path: path) else {
                    self?.fail("\(provider.label) not found on PATH")
                    return
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd.expandingTilde, isDirectory: &isDir), isDir.boolValue else {
                    self?.fail("No folder \(cwd)")
                    return
                }
                launch = .local(binary: exe, arguments: arguments, cwd: cwd, path: path)
            }
            self?.launch(launch)
        }
    }

    /// Sends a user message (queued while the agent starts).
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, driver != nil, state.phase != .ended, state.phase != .failed else { return }
        state.items.append(ChatItem(id: "user-\(state.items.count)-\(UUID().uuidString.prefix(6))", kind: .user, text: text))
        state.phase = .running
        write(driver!.sendLines(text, state: &state))
        changed()
    }

    /// Stops the current turn; the session stays open.
    func interrupt() {
        guard driver != nil, state.phase == .running else { return }
        write(driver!.interruptLines(state: &state))
        changed()
    }

    /// Answers an approval request (`ChatApproval.id`).
    func respond(approval id: String, allow: Bool, always: Bool = false) {
        respond(approval: id, decision: allow ? (always ? .allowAlways : .allow) : .deny)
    }

    func respond(approval id: String, decision: ChatDecision) {
        guard driver != nil, state.pendingApprovals.contains(where: { $0.id == id }) else { return }
        write(driver!.approvalLines(id, decision: decision, state: &state))
        changed()
    }

    /// Ends the agent process (stdin closed, then SIGTERM / SIGKILL).
    func stop() {
        startTask?.cancel()
        startTask = nil
        guard driver != nil else { return }
        stopping = true
        transport?.terminate()
        if transport == nil, state.phase != .failed { state.phase = .ended; changed() }
    }

    // MARK: Internals

    static func localBinary(_ provider: ChatProvider, override: String?, path: String) -> String? {
        let candidates: [String] = switch provider {
        case .claude: ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex: ["/opt/homebrew/bin/codex", "~/.local/bin/codex", "/usr/local/bin/codex"]
        }
        return AgentTools.find(override ?? "", candidates: candidates, name: provider.command, path: path)
    }

    private func launch(_ launch: ChatLaunch) {
        guard !stopping, !Task.isCancelled else { return }
        let t = ChatTransport(launch, onLine: { [weak self] line in self?.receive(line) },
                              onExit: { [weak self] status, err in self?.exited(status, stderr: err) })
        do {
            try t.start()
        } catch {
            fail("Could not start \(launch.executable): \(error.localizedDescription)")
            return
        }
        transport = t
        let lines = queued
        queued = []
        for l in lines { t.send(l) }
    }

    private func write(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        if let transport { for l in lines { transport.send(l) } } else { queued += lines }
    }

    private func receive(_ line: String) {
        guard driver != nil else { return }
        let replies = driver!.handle(line, state: &state)
        write(replies)
        changed()
    }

    private func exited(_ status: Int32, stderr: String) {
        transport = nil
        state.endStreaming()
        state.cancelPendingApprovals()
        if stopping || (status == 0 && state.phase != .starting) {
            if state.phase != .failed { state.phase = .ended }
        } else {
            let tail = stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
            state.error(tail.isEmpty ? "\(provider?.label ?? "Agent") exited with status \(status)" : tail)
            state.phase = .failed
        }
        changed()
    }

    private func fail(_ message: String) {
        state.error(message)
        state.phase = .failed
        changed()
    }

    private func changed() { onChange?() }
}

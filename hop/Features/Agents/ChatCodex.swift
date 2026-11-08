import Foundation

/// Codex through `codex app-server`: JSON-RPC 2.0 lines on stdio, without the "jsonrpc"
/// member. hop sends `initialize`, the `initialized` notification, `thread/start` or
/// `thread/resume`, then `turn/start` per message and `turn/interrupt`. The server streams
/// `item/*` and `turn/*` notifications and asks for approvals with server requests
/// (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, and the
/// older `execCommandApproval` / `applyPatchApproval`), answered with a `decision`.
nonisolated struct ChatCodex: ChatDriver {
    var options: ChatOptions

    private enum Pending { case initialize, thread, turn, interrupt }
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    /// Messages sent before the thread exists.
    private var queuedTexts: [String] = []
    private var threadID: String?
    private var turnID: String?
    /// Approvals waiting on an answer: the request id exactly as it came (JSON), the method,
    /// and the wire decisions the server offered.
    private var approvals: [String: (rawID: String, method: String, available: [String])] = [:]
    private var approvalCount = 0

    init(options: ChatOptions) { self.options = options }

    func arguments() -> [String] { ["app-server"] }

    /// `approvalPolicy` and `sandbox` for thread/start.
    static func policy(_ mode: ChatPermissionMode) -> (approval: String, sandbox: String) {
        switch mode {
        case .ask: ("untrusted", "workspace-write")
        case .acceptEdits, .auto: ("on-request", "workspace-write")
        case .plan: ("on-request", "read-only")
        case .bypass: ("never", "danger-full-access")
        }
    }

    // MARK: Outgoing

    private mutating func request(_ method: String, _ params: Any, _ kind: Pending) -> String {
        nextID += 1
        pending[nextID] = kind
        return ChatJSON.line(["id": nextID, "method": method, "params": params])
    }

    mutating func startLines() -> [String] {
        [request("initialize", ["clientInfo": ["name": "hop", "title": "hop", "version": Self.version],
                                "capabilities": NSNull()], .initialize)]
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    private mutating func threadLines() -> [String] {
        let (approval, sandbox) = Self.policy(options.permissionMode)
        var params: [String: Any] = ["cwd": options.cwd.expandingTilde, "approvalPolicy": approval, "sandbox": sandbox]
        if let model = options.model, !model.isEmpty { params["model"] = model }
        if options.permissionMode == .auto { params["approvalsReviewer"] = "auto_review" }
        let initialized = ChatJSON.line(["method": "initialized"])
        if let resume = options.resume, !resume.isEmpty {
            params["threadId"] = resume
            return [initialized, request("thread/resume", params, .thread)]
        }
        return [initialized, request("thread/start", params, .thread)]
    }

    mutating func sendLines(_ text: String, state: inout ChatState) -> [String] {
        guard let threadID else {
            queuedTexts.append(text)
            return []
        }
        return [turnLine(text, threadID: threadID)]
    }

    private mutating func turnLine(_ text: String, threadID: String) -> String {
        request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": text, "text_elements": [Any]()]]], .turn)
    }

    mutating func interruptLines(state: inout ChatState) -> [String] {
        guard let threadID, let turnID else { return [] }
        return [request("turn/interrupt", ["threadId": threadID, "turnId": turnID], .interrupt)]
    }

    mutating func approvalLines(_ id: String, decision: ChatDecision, state: inout ChatState) -> [String] {
        guard let a = approvals.removeValue(forKey: id) else { return [] }
        state.resolveApproval(id, decision == .deny ? .denied : .allowed)
        if decision == .deny, let item = state.item("approval:" + id)?.approval?.itemID {
            state.update(item) { $0.status = .declined }
        }
        return [Self.approvalResponse(rawID: a.rawID, method: a.method, decision: decision, available: a.available)]
    }

    /// `{"id":<as received>,"result":{"decision":…}}`. v2 requests take accept /
    /// acceptForSession / decline (cancel when decline is not offered); the v1 ones
    /// approved / approved_for_session / denied.
    static func approvalResponse(rawID: String, method: String, decision: ChatDecision, available: [String] = []) -> String {
        let id = ChatJSON.value(rawID) ?? rawID
        let wire: Any
        if method == "execCommandApproval" || method == "applyPatchApproval" {
            switch decision {
            case .allow: wire = "approved"
            case .allowAlways: wire = "approved_for_session"
            case .deny: wire = ["denied": ["rejection": "The user denied this in hop."]]
            }
        } else {
            switch decision {
            case .allow: wire = "accept"
            case .allowAlways: wire = available.isEmpty || available.contains("acceptForSession") ? "acceptForSession" : "accept"
            case .deny: wire = available.isEmpty || available.contains("decline") ? "decline" : "cancel"
            }
        }
        return ChatJSON.line(["id": id, "result": ["decision": wire]])
    }

    // MARK: Incoming

    mutating func handle(_ line: String, state: inout ChatState) -> [String] {
        guard let o = ChatJSON.object(line) else { return [] }
        let method = o["method"] as? String
        if let method, let id = o["id"] {
            return serverRequest(method, id: id, params: o["params"] as? [String: Any] ?? [:], state: &state)
        }
        if let method { notification(method, o["params"] as? [String: Any] ?? [:], state: &state); return [] }
        if let id = o["id"] as? Int, let kind = pending.removeValue(forKey: id) {
            return response(kind, result: o["result"] as? [String: Any], error: o["error"] as? [String: Any], state: &state)
        }
        return []
    }

    private mutating func response(_ kind: Pending, result: [String: Any]?, error: [String: Any]?, state: inout ChatState) -> [String] {
        if let error {
            let message = ChatJSON.message(error["message"] as? String ?? "request failed")
            switch kind {
            case .initialize, .thread:
                state.error(message)
                state.phase = .failed
            case .turn:
                state.error(message)
                state.phase = .idle
            case .interrupt:
                state.notice("Could not interrupt: \(message)")
            }
            return []
        }
        switch kind {
        case .initialize:
            return threadLines()
        case .thread:
            guard let thread = result?["thread"] as? [String: Any], let id = thread["id"] as? String else {
                state.error("Codex did not return a thread")
                state.phase = .failed
                return []
            }
            threadID = id
            state.sessionID = id
            state.model = (result?["model"] as? String) ?? (thread["model"] as? String)
            if state.phase == .starting { state.phase = .idle }
            let texts = queuedTexts
            queuedTexts = []
            if !texts.isEmpty { state.phase = .running }
            return texts.map { turnLine($0, threadID: id) }
        case .turn:
            if let turn = result?["turn"] as? [String: Any], let id = turn["id"] as? String { turnID = id }
            return []
        case .interrupt:
            return []
        }
    }

    private mutating func notification(_ method: String, _ p: [String: Any], state: inout ChatState) {
        switch method {
        case "turn/started":
            if let turn = p["turn"] as? [String: Any], let id = turn["id"] as? String { turnID = id }
            state.phase = .running
        case "turn/completed":
            let turn = p["turn"] as? [String: Any] ?? [:]
            state.endStreaming()
            for i in state.items.indices where state.items[i].status == .running && state.items[i].kind != .approval {
                state.items[i].status = .declined
            }
            switch turn["status"] as? String {
            case "failed":
                let message = (turn["error"] as? [String: Any])?["message"] as? String
                // The `error` notification before it already said why.
                if let message, state.lastError != ChatJSON.message(message) { state.error(ChatJSON.message(message)) }
            case "interrupted":
                state.notice("Interrupted")
            default: break
            }
            state.cancelPendingApprovals()
            approvals = [:]
            turnID = nil
            state.phase = .idle
        case "item/started", "item/completed":
            if let item = p["item"] as? [String: Any] { self.item(item, completed: method == "item/completed", state: &state) }
        case "item/agentMessage/delta":
            if let id = p["itemId"] as? String, let delta = p["delta"] as? String { state.append(delta, to: id) }
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            if let id = p["itemId"] as? String, let delta = p["delta"] as? String {
                state.update(id) { $0.output = ChatState.excerpt(($0.output ?? "") + delta, lines: 40, chars: 6000) }
            }
        case "serverRequest/resolved":
            if let raw = ChatJSON.text(p["requestId"]), let key = approvals.first(where: { $0.value.rawID == raw })?.key {
                approvals[key] = nil
                state.resolveApproval(key, .cancelled)
            }
        case "error":
            let e = p["error"] as? [String: Any] ?? [:]
            let message = ChatJSON.message(e["message"] as? String ?? "error")
            if p["willRetry"] as? Bool == true { state.notice("Retrying: \(message)") } else { state.error(message) }
        case "warning":
            if let m = p["message"] as? String { state.notice(m) }
        case "thread/compacted":
            state.notice("Context compacted")
        default: break
        }
    }

    private func item(_ item: [String: Any], completed: Bool, state: inout ChatState) {
        guard let type = item["type"] as? String, let id = item["id"] as? String else { return }
        switch type {
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            if completed {
                state.upsert(ChatItem(id: id, kind: .assistant, text: text))
            } else if state.index(id) == nil {
                state.items.append(ChatItem(id: id, kind: .assistant, text: text, streaming: true))
            }
        case "commandExecution":
            let actions = item["commandActions"] as? [[String: Any]]
            let command = actions?.compactMap { $0["command"] as? String }.joined(separator: " && ")
            var row = state.item(id) ?? ChatItem(id: id, kind: .tool, text: "", name: "Shell", status: .running)
            row.text = (command?.isEmpty == false ? command : item["command"] as? String) ?? row.text
            row.status = Self.status(item["status"] as? String, exitCode: item["exitCode"] as? Int)
            if let out = item["aggregatedOutput"] as? String, !out.isEmpty { row.output = ChatState.excerpt(out) }
            else if let code = item["exitCode"] as? Int, code != 0, row.output == nil { row.output = "exit \(code)" }
            state.upsert(row)
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            var row = state.item(id) ?? ChatItem(id: id, kind: .fileChange, text: "", name: "Edit", status: .running)
            row.path = paths.first
            row.text = paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
            row.diff = changes.map { c in
                let kind = (c["kind"] as? [String: Any])?["type"] as? String ?? "update"
                return "\(kind) \(c["path"] as? String ?? "")\n\(c["diff"] as? String ?? "")"
            }.joined(separator: "\n")
            row.status = Self.status(item["status"] as? String, exitCode: nil)
            state.upsert(row)
        case "mcpToolCall", "dynamicToolCall":
            let server = item["server"] as? String ?? item["namespace"] as? String
            let tool = item["tool"] as? String ?? "tool"
            var row = state.item(id) ?? ChatItem(id: id, kind: .tool, text: "", name: server.map { "\($0).\(tool)" } ?? tool, status: .running)
            row.text = ClaudeSessions.toolSummary(tool, item["arguments"] as? [String: Any])
            row.status = Self.status(item["status"] as? String, exitCode: nil)
            if let err = (item["error"] as? [String: Any])?["message"] as? String { row.output = err; row.status = .failed }
            state.upsert(row)
        case "webSearch":
            var row = state.item(id) ?? ChatItem(id: id, kind: .tool, text: "", name: "WebSearch", status: .running)
            row.text = item["query"] as? String ?? row.text
            row.status = completed ? .done : .running
            state.upsert(row)
        case "contextCompaction":
            if completed { state.notice("Context compacted") }
        default:
            // userMessage (hop added it when sending), reasoning, plan and the rest.
            break
        }
    }

    static func status(_ raw: String?, exitCode: Int?) -> ChatItem.Status {
        switch raw {
        case "inProgress": .running
        case "failed": .failed
        case "declined": .declined
        case "completed": (exitCode ?? 0) == 0 ? .done : .failed
        default: .running
        }
    }

    private mutating func serverRequest(_ method: String, id: Any, params p: [String: Any], state: inout ChatState) -> [String] {
        guard let rawID = ChatJSON.text(id) else { return [] }
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval":
            let itemID = p["itemId"] as? String ?? p["callId"] as? String
            let available = (p["availableDecisions"] as? [Any])?.compactMap { $0 as? String } ?? []
            // Ids restart every turn ("0"): the approval's own id stays unique in the chat.
            approvalCount += 1
            let key = "\(approvalCount):\(rawID)"
            approvals[key] = (rawID, method, available)
            let isCommand = method.contains("ommand") || method == "execCommandApproval"
            var detail: String
            if isCommand {
                detail = (p["command"] as? String) ?? (p["command"] as? [String])?.joined(separator: " ") ?? ""
                if let actions = p["commandActions"] as? [[String: Any]], let first = actions.first?["command"] as? String { detail = first }
            } else if let changes = p["fileChanges"] as? [String: Any] {
                detail = changes.keys.sorted().map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
            } else {
                // v2 file approvals name only the item: its paths came with item/started.
                detail = itemID.flatMap { state.item($0)?.text } ?? ""
            }
            if detail.isEmpty { detail = isCommand ? "Run a command" : "Edit files" }
            var options: [ChatDecision] = [.allow]
            if available.isEmpty || available.contains("acceptForSession") || method == "execCommandApproval" || method == "applyPatchApproval" {
                options.append(.allowAlways)
            }
            options.append(.deny)
            state.addApproval(ChatApproval(id: key, kind: isCommand ? .command : .fileChange, title: isCommand ? "Run command" : "Edit files",
                                           detail: detail, reason: p["reason"] as? String, options: options, itemID: itemID))
            return []
        default:
            // Questions, MCP elicitations, dynamic tools, auth refresh: not supported yet.
            state.notice("Codex asked for \(method), which hop does not handle")
            return [ChatJSON.line(["id": id, "error": ["code": -32601, "message": "hop does not handle \(method)"]])]
        }
    }
}

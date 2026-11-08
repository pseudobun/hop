import Foundation

/// Claude Code in stream-json mode: `claude -p --input-format stream-json --output-format
/// stream-json --verbose --permission-prompt-tool stdio`. The same wire format the Agent SDK
/// speaks: user messages and `control_request` / `control_response` frames on stdin, SDK
/// messages (system, assistant, user, stream_event, result) and the CLI's own
/// `control_request`s (`can_use_tool`) on stdout.
nonisolated struct ChatClaude: ChatDriver {
    var options: ChatOptions

    /// Our control requests by id ("hop-1"): their subtype.
    private var requests: [String: String] = [:]
    private var nextRequest = 0
    /// can_use_tool requests waiting on an answer: the tool input and suggested rules, as JSON.
    private var permissionInputs: [String: (input: String?, suggestions: String?)] = [:]
    /// Text blocks of the current API message streamed so far (item ids, in order); the full
    /// assistant frame that follows replaces their text.
    private var streamed: [String] = []
    private var streamBlocks: [Int: String] = [:]
    private var streamCount = 0
    private var interrupted = false

    init(options: ChatOptions) { self.options = options }

    static let toolsEditingFiles: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    func arguments() -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    "--permission-mode", Self.permissionMode(options.permissionMode)]
        if options.permissionMode == .bypass { args.append("--allow-dangerously-skip-permissions") }
        if let resume = options.resume, !resume.isEmpty { args += ["--resume", resume] }
        if let model = options.model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    static func permissionMode(_ mode: ChatPermissionMode) -> String {
        switch mode {
        case .ask: "default"
        case .acceptEdits: "acceptEdits"
        case .auto: "auto"
        case .plan: "plan"
        case .bypass: "bypassPermissions"
        }
    }

    // MARK: Outgoing

    mutating func startLines() -> [String] {
        [controlRequest(["subtype": "initialize"])]
    }

    mutating func sendLines(_ text: String, state: inout ChatState) -> [String] {
        interrupted = false
        return [Self.userMessage(text, sessionID: state.sessionID)]
    }

    mutating func interruptLines(state: inout ChatState) -> [String] {
        interrupted = true
        return [controlRequest(["subtype": "interrupt"])]
    }

    mutating func approvalLines(_ id: String, decision: ChatDecision, state: inout ChatState) -> [String] {
        let stored = permissionInputs.removeValue(forKey: id)
        if decision == .deny, let item = state.item("approval:" + id)?.approval?.itemID {
            state.update(item) { $0.status = .declined }
        }
        state.resolveApproval(id, decision == .deny ? .denied : .allowed)
        return [Self.permissionResponse(requestID: id, decision: decision, input: stored?.input, suggestions: stored?.suggestions)]
    }

    /// A user turn: `{"type":"user","message":{"role":"user","content":[text]},…}`.
    static func userMessage(_ text: String, sessionID: String?) -> String {
        ChatJSON.line([
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID ?? "",
            // Typed by a person: hosts wrapping keyboard input stamp this.
            "origin": ["kind": "human"],
        ])
    }

    /// The answer to a `can_use_tool` request. Allow sends the input back unchanged
    /// (`updatedInput` is required); always-allow adds the CLI's own suggested rules.
    static func permissionResponse(requestID: String, decision: ChatDecision, input: String?, suggestions: String?) -> String {
        var result: [String: Any]
        switch decision {
        case .allow, .allowAlways:
            result = ["behavior": "allow", "updatedInput": ChatJSON.value(input) ?? [String: Any]()]
            if decision == .allowAlways, let rules = ChatJSON.value(suggestions) as? [Any], !rules.isEmpty {
                result["updatedPermissions"] = rules
            }
        case .deny:
            result = ["behavior": "deny", "message": "The user denied this in hop."]
        }
        return ChatJSON.line(["type": "control_response",
                              "response": ["subtype": "success", "request_id": requestID, "response": result]])
    }

    private mutating func controlRequest(_ request: [String: Any]) -> String {
        nextRequest += 1
        let id = "hop-\(nextRequest)"
        requests[id] = request["subtype"] as? String
        return ChatJSON.line(["type": "control_request", "request_id": id, "request": request])
    }

    // MARK: Incoming

    mutating func handle(_ line: String, state: inout ChatState) -> [String] {
        guard let o = ChatJSON.object(line), let type = o["type"] as? String else { return [] }
        // Subagent traffic (inside a Task call) is not shown in the main chat.
        if let parent = o["parent_tool_use_id"] as? String, !parent.isEmpty, type != "control_request" { return [] }
        switch type {
        case "system": system(o, state: &state)
        case "stream_event": streamEvent(o["event"] as? [String: Any] ?? [:], state: &state)
        case "assistant": assistant(o, state: &state)
        case "user": user(o, state: &state)
        case "result": result(o, state: &state)
        case "control_request": return controlRequest(from: o, state: &state)
        case "control_response": controlResponse(o["response"] as? [String: Any] ?? [:], state: &state)
        case "control_cancel_request":
            if let id = o["request_id"] as? String {
                permissionInputs[id] = nil
                state.resolveApproval(id, .cancelled)
            }
        default: break
        }
        return []
    }

    private mutating func system(_ o: [String: Any], state: inout ChatState) {
        switch o["subtype"] as? String {
        case "init":
            if let id = o["session_id"] as? String { state.sessionID = id }
            if let model = o["model"] as? String { state.model = model }
            if state.phase == .starting { state.phase = .idle }
        case "session_state_changed":
            switch o["state"] as? String {
            case "running", "requires_action": state.phase = .running
            case "idle": if state.phase == .running { state.phase = .idle }
            default: break
            }
        case "compact_boundary":
            state.notice("Context compacted")
        case "api_retry":
            let attempt = (o["attempt"] as? Int).map { " (attempt \($0))" } ?? ""
            state.notice("Retrying the API request" + attempt)
        default: break
        }
    }

    private mutating func streamEvent(_ e: [String: Any], state: inout ChatState) {
        switch e["type"] as? String {
        case "message_start":
            streamBlocks = [:]
        case "content_block_start":
            guard let block = e["content_block"] as? [String: Any], block["type"] as? String == "text", let index = e["index"] as? Int else { return }
            streamCount += 1
            let id = "stream-\(streamCount)"
            streamBlocks[index] = id
            streamed.append(id)
            state.append(block["text"] as? String ?? "", to: id)
        case "content_block_delta":
            guard let delta = e["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let index = e["index"] as? Int, let id = streamBlocks[index], let text = delta["text"] as? String else { return }
            state.append(text, to: id)
        default: break
        }
    }

    private mutating func assistant(_ o: [String: Any], state: inout ChatState) {
        guard let message = o["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return }
        let messageID = message["id"] as? String ?? o["uuid"] as? String ?? UUID().uuidString
        if let model = message["model"] as? String, state.model == nil { state.model = model }
        for (n, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                if !streamed.isEmpty {
                    let id = streamed.removeFirst()
                    state.update(id) { $0.text = text; $0.streaming = false }
                } else if !text.isEmpty {
                    state.upsert(ChatItem(id: "\(messageID)-\(o["uuid"] as? String ?? String(n))", kind: .assistant, text: text))
                }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                state.upsert(Self.toolItem(id: id, name: name, input: input))
            default: break
            }
        }
    }

    /// A tool call row; file-editing tools become file changes with a diff of their input.
    static func toolItem(id: String, name: String, input: [String: Any]?) -> ChatItem {
        let summary = ClaudeSessions.toolSummary(name, input)
        guard toolsEditingFiles.contains(name), let input else {
            return ChatItem(id: id, kind: .tool, text: summary, name: name, status: .running)
        }
        let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
        return ChatItem(id: id, kind: .fileChange, text: summary, name: name, status: .running, path: path, diff: editDiff(name, input))
    }

    /// `-`/`+` lines from Write / Edit / MultiEdit input.
    static func editDiff(_ name: String, _ input: [String: Any]) -> String? {
        func lines(_ s: String?, _ prefix: String) -> [String] {
            guard let s, !s.isEmpty else { return [] }
            return s.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }
        }
        switch name {
        case "Write":
            return lines(input["content"] as? String, "+").joined(separator: "\n")
        case "Edit":
            return (lines(input["old_string"] as? String, "-") + lines(input["new_string"] as? String, "+")).joined(separator: "\n")
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return edits.map { (lines($0["old_string"] as? String, "-") + lines($0["new_string"] as? String, "+")).joined(separator: "\n") }
                .joined(separator: "\n@@\n")
        case "NotebookEdit":
            return lines(input["new_source"] as? String, "+").joined(separator: "\n")
        default:
            return nil
        }
    }

    private func user(_ o: [String: Any], state: inout ChatState) {
        guard let message = o["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String else { continue }
            let isError = block["is_error"] as? Bool ?? false
            let output = ClaudeSessions.resultText(block["content"])
            state.update(id) {
                $0.status = isError ? ($0.status == .declined ? .declined : .failed) : .done
                if !output.isEmpty { $0.output = output }
            }
        }
    }

    private mutating func result(_ o: [String: Any], state: inout ChatState) {
        if let id = o["session_id"] as? String { state.sessionID = id }
        state.endStreaming()
        streamed = []
        streamBlocks = [:]
        for i in state.items.indices where state.items[i].status == .running && state.items[i].kind != .approval {
            state.items[i].status = interrupted ? .declined : .done
        }
        let subtype = o["subtype"] as? String ?? "success"
        if interrupted {
            state.notice("Interrupted")
        } else if o["is_error"] as? Bool == true || subtype != "success" {
            let text = (o["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (o["errors"] as? [String])?.joined(separator: "\n") ?? subtype.replacingOccurrences(of: "_", with: " ")
            state.error(text)
        }
        interrupted = false
        state.cancelPendingApprovals()
        state.phase = .idle
    }

    private mutating func controlRequest(from o: [String: Any], state: inout ChatState) -> [String] {
        guard let id = o["request_id"] as? String, let request = o["request"] as? [String: Any] else { return [] }
        guard request["subtype"] as? String == "can_use_tool" else {
            // hook callbacks, MCP messages, dialogs: hop registers none of them.
            return [ChatJSON.line(["type": "control_response",
                                   "response": ["subtype": "error", "request_id": id, "error": "hop does not handle \(request["subtype"] as? String ?? "this request")"]])]
        }
        let tool = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? [String: Any]
        let suggestions = request["permission_suggestions"] as? [Any]
        permissionInputs[id] = (ChatJSON.text(input ?? [:]), suggestions.flatMap { $0.isEmpty ? nil : ChatJSON.text($0) })
        var detail = ClaudeSessions.toolSummary(tool, input)
        if detail.isEmpty { detail = request["description"] as? String ?? request["title"] as? String ?? tool }
        let reason = request["decision_reason"] as? String
        var options: [ChatDecision] = [.allow]
        if suggestions?.isEmpty == false { options.append(.allowAlways) }
        options.append(.deny)
        state.addApproval(ChatApproval(id: id, kind: .tool, title: request["display_name"] as? String ?? tool, detail: detail,
                                       reason: reason, options: options, itemID: request["tool_use_id"] as? String, toolName: tool))
        return []
    }

    private mutating func controlResponse(_ r: [String: Any], state: inout ChatState) {
        guard let id = r["request_id"] as? String, let subtype = requests.removeValue(forKey: id) else { return }
        if r["subtype"] as? String == "error" {
            state.error("\(subtype): \(r["error"] as? String ?? "failed")")
            if subtype == "initialize" { state.phase = .failed }
            return
        }
        if subtype == "initialize", state.phase == .starting { state.phase = .idle }
    }
}

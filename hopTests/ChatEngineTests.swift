import Foundation
import Testing
@testable import hop

/// Chat engine drivers, fed with trimmed output recorded from Claude Code 2.1.318 and
/// codex-cli 0.163 (`hopTests/Fixtures/chat_*.jsonl`).
struct ChatEngineTests {
    private static func lines(_ name: String) -> [String] {
        Fixtures.text(name).split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func json(_ line: String) throws -> [String: Any] { try #require(ChatJSON.object(line)) }

    /// Feeds lines; when an approval is pending, answers it with `decision` and records what was written.
    private static func replay<D: ChatDriver>(_ driver: inout D, _ lines: [String], state: inout ChatState,
                                              decision: ChatDecision = .allow, written: inout [String]) {
        for line in lines {
            written += driver.handle(line, state: &state)
            if let a = state.pendingApprovals.first {
                written += driver.approvalLines(a.id, decision: decision, state: &state)
            }
        }
    }

    // MARK: - Transport

    @Test func lineBufferSplitsPartialLines() {
        var b = ChatLineBuffer()
        #expect(b.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(b.append(Data(":2}\r\n\n{\"c\":3}".utf8)) == ["{\"b\":2}"])
        #expect(b.append(Data("é".utf8).prefix(1)).isEmpty)
        #expect(b.append(Data("é\n".utf8).suffix(2)) == ["{\"c\":3}é"])
        #expect(b.append(Data("x".utf8)).isEmpty)
        #expect(b.finish() == ["x"])
        var c = ChatLineBuffer()
        _ = c.append(Data("tail".utf8))
        #expect(c.finish() == ["tail"] && c.finish().isEmpty)
    }

    @Test func remoteLaunchExecsTheAgentFromAScript() {
        let l = ChatLaunch.remote(ssh: "olympus", command: ["claude", "-p", "--model", "it's"], cwd: "~/repos/hop")
        #expect(l.executable == "/usr/bin/ssh" && l.arguments == AgentCommands.sshArguments("olympus") && l.cwd == nil)
        let script = try! #require(l.preamble)
        #expect(script.hasPrefix("cd \"$HOME\"/'repos/hop' || {"))
        #expect(script.contains("command -v 'claude' >/dev/null 2>&1 || {"))
        #expect(script.contains("\nexec 'claude' '-p' '--model' 'it'\\''s'\n"))
        let local = ChatLaunch.local(binary: "/bin/claude", arguments: ["-p"], cwd: "/tmp", path: "/x:/y")
        #expect(local.environment?["PATH"] == "/x:/y" && local.environment?["CLAUDECODE"] == nil && local.preamble == nil)
    }

    // MARK: - Claude Code

    @Test func claudeArgumentsAndFraming() throws {
        let c = ChatClaude(options: ChatOptions(cwd: "/tmp", permissionMode: .acceptEdits, resume: "abc", model: "haiku"))
        #expect(c.arguments() == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                  "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "acceptEdits",
                                  "--resume", "abc", "--model", "haiku"])
        #expect(ChatClaude(options: ChatOptions(cwd: "/", permissionMode: .bypass)).arguments().contains("--allow-dangerously-skip-permissions"))

        #expect(ChatClaude.userMessage("hi \"you\"", sessionID: nil)
            == #"{"message":{"content":[{"text":"hi \"you\"","type":"text"}],"role":"user"},"origin":{"kind":"human"},"parent_tool_use_id":null,"session_id":"","type":"user"}"#)

        let allow = ChatClaude.permissionResponse(requestID: "r1", decision: .allow, input: #"{"file_path":"/a"}"#, suggestions: #"[{"type":"setMode"}]"#)
        #expect(allow == #"{"response":{"request_id":"r1","response":{"behavior":"allow","updatedInput":{"file_path":"/a"}},"subtype":"success"},"type":"control_response"}"#)
        let always = try Self.json(ChatClaude.permissionResponse(requestID: "r1", decision: .allowAlways, input: nil, suggestions: #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#))
        let r = try #require((always["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect((r["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String == "acceptEdits")
        #expect((r["updatedInput"] as? [String: Any])?.isEmpty == true)
        let deny = ChatClaude.permissionResponse(requestID: "r2", decision: .deny, input: nil, suggestions: nil)
        #expect(deny == #"{"response":{"request_id":"r2","response":{"behavior":"deny","message":"The user denied this in hop."},"subtype":"success"},"type":"control_response"}"#)

        var d = ChatClaude(options: ChatOptions(cwd: "/tmp"))
        #expect(d.startLines() == [#"{"request":{"subtype":"initialize"},"request_id":"hop-1","type":"control_request"}"#])
        var state = ChatState()
        #expect(d.interruptLines(state: &state) == [#"{"request":{"subtype":"interrupt"},"request_id":"hop-2","type":"control_request"}"#])
        // initialize answered: ready.
        _ = d.handle(#"{"type":"control_response","response":{"subtype":"success","request_id":"hop-1","response":{}}}"#, state: &state)
        #expect(state.phase == .idle && state.status == .idle)
        // Requests hop does not serve get an error reply.
        let reply = d.handle(#"{"type":"control_request","request_id":"x9","request":{"subtype":"hook_callback"}}"#, state: &state)
        #expect(try Self.json(reply[0])["type"] as? String == "control_response" && reply[0].contains(#""subtype":"error""#))
    }

    @Test func claudeReplyStreamsIntoOneAssistantRow() {
        var d = ChatClaude(options: ChatOptions(cwd: "/tmp"))
        var state = ChatState()
        state.phase = .running
        var out: [String] = []
        let lines = Self.lines("chat_claude_ok.jsonl")
        // Mid-stream: the delta made a streaming row.
        for line in lines.prefix(4) { out += d.handle(line, state: &state) }
        #expect(state.items.count == 1 && state.items[0].streaming && state.items[0].text == "ok")
        Self.replay(&d, Array(lines.dropFirst(4)), state: &state, written: &out)
        #expect(out.isEmpty)
        #expect(state.sessionID == "39f5458e-665b-443a-9771-6607b1566351" && state.model == "claude-haiku-5-5")
        #expect(state.items.map(\.kind) == [.assistant] && state.items[0].text == "ok" && !state.items[0].streaming)
        #expect(state.status == .idle && state.lastError == nil)
    }

    @Test func claudePermissionRequestAndFileChange() throws {
        var d = ChatClaude(options: ChatOptions(cwd: "/tmp"))
        var state = ChatState()
        state.phase = .running
        let lines = Self.lines("chat_claude_permission.jsonl")
        let ask = try #require(lines.firstIndex { $0.contains("can_use_tool") })
        for line in lines[...ask] { _ = d.handle(line, state: &state) }

        #expect(state.status == .waitingForApproval)
        let a = try #require(state.pendingApprovals.first)
        #expect(a.id == "56f1419e-6f1a-42b6-9378-a85016dd064b" && a.kind == .tool && a.title == "Write" && a.toolName == "Write")
        #expect(a.detail == "/private/tmp/claude-501/l2-engine/cc2/hello.txt" && a.options == [.allow, .allowAlways, .deny])
        #expect(a.itemID == "toolu_016tk4eFmoWjFugXyAXDDx8G")
        let edit = try #require(state.item("toolu_016tk4eFmoWjFugXyAXDDx8G"))
        #expect(edit.kind == .fileChange && edit.status == .running && edit.path == "/private/tmp/claude-501/l2-engine/cc2/hello.txt" && edit.diff == "+hi\n+")

        let answer = d.approvalLines(a.id, decision: .allow, state: &state)
        let r = try #require((try Self.json(answer[0])["response"] as? [String: Any]))
        #expect(r["request_id"] as? String == a.id)
        let body = try #require(r["response"] as? [String: Any])
        #expect(body["behavior"] as? String == "allow" && (body["updatedInput"] as? [String: Any])?["content"] as? String == "hi\n")
        #expect(state.status == .running && state.item("approval:" + a.id)?.approval?.state == .allowed)

        var out: [String] = []
        Self.replay(&d, Array(lines[(ask + 1)...]), state: &state, written: &out)
        #expect(out.isEmpty)
        #expect(state.item("toolu_016tk4eFmoWjFugXyAXDDx8G")?.status == .done)
        #expect(state.item("toolu_016tk4eFmoWjFugXyAXDDx8G")?.output?.hasPrefix("File created successfully") == true)
        #expect(state.items.map(\.kind) == [.fileChange, .approval, .assistant])
        #expect(state.items.last?.text.contains("hello.txt") == true && state.status == .idle)
    }

    @Test func claudeDenyMarksTheToolDeclined() throws {
        var d = ChatClaude(options: ChatOptions(cwd: "/tmp"))
        var state = ChatState()
        state.phase = .running
        var out: [String] = []
        let lines = Self.lines("chat_claude_permission.jsonl")
        let ask = try #require(lines.firstIndex { $0.contains("can_use_tool") })
        Self.replay(&d, Array(lines[...ask]), state: &state, decision: .deny, written: &out)
        #expect(out.count == 1 && out[0].contains(#""behavior":"deny""#))
        #expect(state.item("toolu_016tk4eFmoWjFugXyAXDDx8G")?.status == .declined && state.pendingApprovals.isEmpty)
        // The CLI withdraws a request (interrupt): it is cancelled, not answered.
        _ = d.handle(#"{"type":"control_request","request_id":"q2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"permission_suggestions":[]}}"#, state: &state)
        #expect(state.pendingApprovals.first?.options == [.allow, .deny] && state.pendingApprovals.first?.detail == "ls")
        _ = d.handle(#"{"type":"control_cancel_request","request_id":"q2"}"#, state: &state)
        #expect(state.pendingApprovals.isEmpty && state.item("approval:q2")?.approval?.state == .cancelled)
    }

    @Test func claudeErrorResultAndSubagentTraffic() {
        var d = ChatClaude(options: ChatOptions(cwd: "/tmp"))
        var state = ChatState()
        state.phase = .running
        _ = d.handle(#"{"type":"assistant","parent_tool_use_id":"toolu_task","message":{"id":"m","content":[{"type":"text","text":"sub"}]}}"#, state: &state)
        #expect(state.items.isEmpty)
        _ = d.handle(#"{"type":"assistant","parent_tool_use_id":null,"message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make test\nmore"}}]}}"#, state: &state)
        #expect(state.item("t1")?.text == "make test" && state.item("t1")?.name == "Bash" && state.item("t1")?.kind == .tool)
        _ = d.handle(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#, state: &state)
        #expect(state.item("t1")?.status == .failed && state.item("t1")?.output == "boom")
        _ = d.handle(#"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s1"}"#, state: &state)
        #expect(state.lastError == "error max turns" && state.items.last?.kind == .error && state.phase == .idle)
    }

    // MARK: - Codex

    /// Sends `text` before the thread exists, as the engine does right after start.
    private static func codexStarted(_ text: String) -> (ChatCodex, ChatState, [String]) {
        var d = ChatCodex(options: ChatOptions(cwd: "/private/tmp/claude-501/l2-engine/cx1", permissionMode: .ask))
        var state = ChatState()
        var out = d.startLines()
        state.items.append(ChatItem(id: "u", kind: .user, text: text))
        state.phase = .running
        out += d.sendLines(text, state: &state)
        return (d, state, out)
    }

    @Test func codexHandshakeQueuesTheFirstTurn() throws {
        var (d, state, out) = Self.codexStarted("hi")
        #expect(out.count == 1)
        let initialize = try Self.json(out[0])
        #expect(initialize["id"] as? Int == 1 && initialize["method"] as? String == "initialize")
        #expect(((initialize["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String == "hop")

        let lines = Self.lines("chat_codex_command.jsonl")
        out = d.handle(lines[0], state: &state)
        #expect(out.count == 2 && out[0] == #"{"method":"initialized"}"#)
        let start = try Self.json(out[1])
        let params = try #require(start["params"] as? [String: Any])
        #expect(start["id"] as? Int == 2 && start["method"] as? String == "thread/start")
        #expect(params["approvalPolicy"] as? String == "untrusted" && params["sandbox"] as? String == "workspace-write")
        #expect(params["cwd"] as? String == "/private/tmp/claude-501/l2-engine/cx1")

        out = d.handle(lines[1], state: &state)
        #expect(state.sessionID == "01a1bc70-e643-7320-9782-2d3fa07bef2d" && state.model == "gpt-6-astra")
        #expect(out == [#"{"id":3,"method":"turn/start","params":{"input":[{"text":"hi","text_elements":[],"type":"text"}],"threadId":"01a1bc70-e643-7320-9782-2d3fa07bef2d"}}"#])

        // Resume asks for thread/resume with the id.
        var r = ChatCodex(options: ChatOptions(cwd: "/x", permissionMode: .bypass, resume: "t-1", model: "gpt"))
        var s2 = ChatState()
        _ = r.startLines()
        let resume = try Self.json(r.handle(#"{"id":1,"result":{}}"#, state: &s2)[1])
        let rp = try #require(resume["params"] as? [String: Any])
        #expect(resume["method"] as? String == "thread/resume" && rp["threadId"] as? String == "t-1" && rp["model"] as? String == "gpt")
        #expect(rp["approvalPolicy"] as? String == "never" && rp["sandbox"] as? String == "danger-full-access")
    }

    @Test func codexCommandApprovalAndMessages() throws {
        var (d, state, _) = Self.codexStarted("Create a file")
        var out: [String] = []
        let lines = Self.lines("chat_codex_command.jsonl")
        let ask = try #require(lines.firstIndex { $0.contains("item/commandExecution/requestApproval") })
        for line in lines[..<ask] { out += d.handle(line, state: &state) }
        #expect(state.item("msg_07c415652e05bd16016af0c0c658c087d2b311b839db18b511")?.text == "I’ll create `hello.txt` with the word `hi`.\n")
        _ = d.handle(lines[ask], state: &state)
        #expect(state.status == .waitingForApproval)
        let a = try #require(state.pendingApprovals.first)
        #expect(a.kind == .command && a.detail == "printf 'hi\\n' > hello.txt" && a.options == [.allow, .deny])
        #expect(a.itemID == "exec-c55de94d-3783-4a7b-90ab-0d5cdc8dbf0f")
        // The server offered accept, an execpolicy amendment and cancel: deny becomes cancel.
        var copy = d
        var s = state
        #expect(copy.approvalLines(a.id, decision: .deny, state: &s) == [#"{"id":0,"result":{"decision":"cancel"}}"#])
        #expect(d.approvalLines(a.id, decision: .allow, state: &state) == [#"{"id":0,"result":{"decision":"accept"}}"#])
        #expect(d.approvalLines(a.id, decision: .allow, state: &state).isEmpty)  // answered once
    }

    @Test func codexCommandRunsAfterAccept() throws {
        var (d, state, _) = Self.codexStarted("Create a file")
        var out: [String] = []
        Self.replay(&d, Self.lines("chat_codex_command.jsonl"), state: &state, written: &out)
        #expect(out.contains(#"{"id":0,"result":{"decision":"accept"}}"#))
        let cmd = try #require(state.item("exec-c55de94d-3783-4a7b-90ab-0d5cdc8dbf0f"))
        #expect(cmd.kind == .tool && cmd.name == "Shell" && cmd.status == .done && cmd.text == "printf 'hi\\n' > hello.txt")
        #expect(state.items.map(\.kind) == [.user, .assistant, .tool, .approval, .assistant])
        #expect(state.items.last?.text == "done" && state.status == .idle && state.sessionID != nil)
        #expect(state.item("approval:" + (state.items[3].approval?.id ?? ""))?.approval?.state == .allowed)
    }

    @Test func codexFileChangeApproval() throws {
        var (d, state, _) = Self.codexStarted("Use apply_patch")
        var out: [String] = []
        let lines = Self.lines("chat_codex_patch.jsonl")
        let ask = try #require(lines.firstIndex { $0.contains("item/fileChange/requestApproval") })
        for line in lines[...ask] { out += d.handle(line, state: &state) }
        let a = try #require(state.pendingApprovals.first)
        #expect(a.kind == .fileChange && a.title == "Edit files" && a.options == [.allow, .allowAlways, .deny])
        #expect(a.detail == "/private/tmp/claude-501/l2-engine/cx1/notes.md")
        #expect(d.approvalLines(a.id, decision: .allowAlways, state: &state) == [#"{"id":0,"result":{"decision":"acceptForSession"}}"#])
        Self.replay(&d, Array(lines[(ask + 1)...]), state: &state, written: &out)
        let change = try #require(state.item("exec-9879d970-ec26-4ded-a8bf-2de898b90091"))
        #expect(change.kind == .fileChange && change.status == .done && change.path == "/private/tmp/claude-501/l2-engine/cx1/notes.md")
        #expect(change.diff == "add /private/tmp/claude-501/l2-engine/cx1/notes.md\nhi\n")
        #expect(state.status == .idle && state.items.last?.kind == .assistant)
    }

    @Test func codexTurnErrorBecomesOneErrorRow() {
        var (d, state, _) = Self.codexStarted("reply with the word ok")
        var out: [String] = []
        Self.replay(&d, Self.lines("chat_codex_error.jsonl"), state: &state, written: &out)
        let errors = state.items.filter { $0.kind == .error }
        #expect(errors.count == 1 && errors[0].text == "The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account.")
        #expect(state.status == .idle && state.lastError == errors[0].text)
    }

    @Test func codexApprovalResponses() {
        #expect(ChatCodex.approvalResponse(rawID: "7", method: "item/fileChange/requestApproval", decision: .deny)
            == #"{"id":7,"result":{"decision":"decline"}}"#)
        #expect(ChatCodex.approvalResponse(rawID: #""req-a""#, method: "item/commandExecution/requestApproval", decision: .allowAlways,
                                           available: ["accept", "acceptForSession", "decline"]) == #"{"id":"req-a","result":{"decision":"acceptForSession"}}"#)
        #expect(ChatCodex.approvalResponse(rawID: "1", method: "execCommandApproval", decision: .allow) == #"{"id":1,"result":{"decision":"approved"}}"#)
        #expect(ChatCodex.approvalResponse(rawID: "1", method: "applyPatchApproval", decision: .deny)
            == #"{"id":1,"result":{"decision":{"denied":{"rejection":"The user denied this in hop."}}}}"#)

        // Approvals with the same JSON-RPC id in later turns stay separate rows.
        var d = ChatCodex(options: ChatOptions(cwd: "/x"))
        var state = ChatState()
        state.phase = .running
        let req = #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"itemId":"i","command":"ls"}}"#
        _ = d.handle(req, state: &state)
        let first = state.pendingApprovals[0].id
        _ = d.approvalLines(first, decision: .allow, state: &state)
        _ = d.handle(req, state: &state)
        #expect(state.items.filter { $0.kind == .approval }.count == 2 && state.pendingApprovals.count == 1)
        // Withdrawn by the server: cancelled.
        _ = d.handle(#"{"method":"serverRequest/resolved","params":{"threadId":"t","requestId":0}}"#, state: &state)
        #expect(state.pendingApprovals.isEmpty)
        // Unknown server requests get a JSON-RPC error.
        let reply = d.handle(#"{"method":"item/tool/requestUserInput","id":5,"params":{}}"#, state: &state)
        #expect(reply == [#"{"error":{"code":-32601,"message":"hop does not handle item/tool/requestUserInput"},"id":5}"#])
        #expect(d.interruptLines(state: &state).isEmpty)  // no turn yet
    }

    @Test func itemsMapToTranscriptEntries() {
        #expect(ChatItem(id: "t", kind: .tool, text: "ls", name: "Bash").transcriptEntry == TranscriptEntry(kind: .tool(name: "Bash"), text: "ls", date: nil, toolID: "t"))
        #expect(ChatItem(id: "e", kind: .error, text: "x").transcriptEntry.kind == .result(isError: true))
        #expect(ChatJSON.message(#"{"type":"error","error":{"message":"inner"}}"#) == "inner" && ChatJSON.message("plain") == "plain")
    }
}

import Foundation
import Testing
@testable import hop

struct AgentsTests {
    private static func jsonl(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    // MARK: - Claude Code

    @Test func registryRecordAndStatus() throws {
        let json = """
        {"pid":73968,"sessionId":"699e5857-cb71","cwd":"/Users/me/repos","startedAt":1794134720083,"kind":"interactive","tmux":"hop-cc-x-1",
         "name":"side-project","bridgeSessionId":"session_014VUM","updatedAt":1794138193533,"status":"waiting"}
        """
        let r = try #require(ClaudeSessions.parseRecord(Data(json.utf8)))
        #expect(r.pid == 73968 && r.sessionID == "699e5857-cb71" && r.cwd == "/Users/me/repos" && r.name == "side-project")
        #expect(r.bridgeSessionID == "session_014VUM" && r.status == "waiting" && r.tmux == "hop-cc-x-1")
        #expect(r.updatedAt == Date(timeIntervalSince1970: 1794138193.533))
        #expect(ClaudeSessions.parseRecord(Data("{\"pid\": 1}".utf8)) == nil)
        #expect(ClaudeSessions.tmuxSessionName("hop-cc-a-1:0.1") == "hop-cc-a-1" && ClaudeSessions.tmuxSessionName("%3") == nil)
        #expect(ClaudeSessions.tmuxSessionName("") == nil && ClaudeSessions.tmuxSessionName("work") == "work")

        #expect(AgentStatus.claude("busy") == .running && AgentStatus.claude("shell") == .running)
        #expect(AgentStatus.claude("waiting") == .waiting && AgentStatus.claude("idle") == .idle && AgentStatus.claude(nil) == .idle)

        let pending = ClaudeSessions.Summary(pendingTool: "Bash")
        let s = ClaudeSessions.session(r, summary: pending, transcript: nil)
        #expect(s.status == .waiting && s.detail == "Bash permission" && s.title == "side-project")
        #expect(s.webURL == URL(string: "https://claude.ai/code/session_014VUM"))
        #expect(s.key == "local/claude/699e5857-cb71")
    }

    @Test func liveRecordsSkipDeadProcessesAndTheDaemon() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (pid, kind) in [(10, "interactive"), (11, "daemon"), (12, "bg")] {
            try Data(#"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/x","kind":"\#(kind)"}"#.utf8).write(to: dir.appending(path: "\(pid).json"))
        }
        try Data("junk".utf8).write(to: dir.appending(path: "13.json"))
        try Data("{}".utf8).write(to: dir.appending(path: "10.abc.key"))
        let live = ClaudeSessions.liveRecords(in: dir) { $0 != 12 }
        #expect(live.map(\.sessionID) == ["s10"])
    }

    @Test func transcriptTailBecomesEntries() {
        let data = Self.jsonl([
            #"{"type":"custom-title","customTitle":"fix login","sessionId":"a"}"#,
            #"{"type":"attachment","cwd":"/Users/me/early","attachment":{"type":"hook_success"}}"#,
            #"{"type":"user","message":{"role":"user","content":"Fix the login bug"},"cwd":"/Users/me/app","timestamp":"2026-11-08T10:45:21.068Z"}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Looking."}]},"timestamp":"2026-11-08T10:45:22Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status\nmore","description":"Status"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"On branch main\nnothing to commit\nline3\nline4\nline5"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent noise"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"<command-name>/compact</command-name>"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/tmp/a.swift"}}]}}"#,
            "not json",
        ])
        let s = ClaudeSessions.parse(data)
        #expect(s.title == "fix login")
        #expect(s.cwd == "/Users/me/app" && s.model == "claude-opus-5-5")
        #expect(s.lastActivity == ClaudeSessions.parseDate("2026-11-08T10:45:22Z"))
        #expect(s.entries.map(\.kind) == [.user, .assistant, .tool(name: "Bash"), .result(isError: false), .notice, .tool(name: "Edit")])
        #expect(s.entries[2].text == "git status")
        #expect(s.entries[3].text == "On branch main\nnothing to commit\nline3\nline4")
        #expect(s.entries[4].text == "/compact")
        #expect(s.entries[5].text == "/tmp/a.swift")
        #expect(s.pendingTool == "Edit")
        #expect(ClaudeSessions.parse(data, limit: 2).entries.count == 2)
        #expect(ClaudeSessions.parse(Data(#"{"type":"attachment","cwd":"/only/here"}"#.utf8)).cwd == "/only/here")
    }

    @Test func answeredToolIsNotPending() {
        let data = Self.jsonl([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"denied"}]}]}}"#,
        ])
        let s = ClaudeSessions.parse(data)
        #expect(s.pendingTool == nil)
        #expect(s.entries.last == TranscriptEntry(kind: .result(isError: true), text: "denied", date: nil))
    }

    @Test func tailStartsAtALineBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hop-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first line that is long\nsecond\nthird\n".utf8).write(to: url)
        #expect(ClaudeSessions.tail(of: url, bytes: 15).map { String(decoding: $0, as: UTF8.self) } == "second\nthird\n")
        #expect(ClaudeSessions.tail(of: url, bytes: 1000).map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("first") == true)
    }

    @Test func projectFolderNames() {
        #expect(ClaudeSessions.encodedProjectName("/Users/me/repos/hop") == "-Users-me-repos-hop")
        #expect(ClaudeSessions.encodedProjectName("/Users/me/My App.v2") == "-Users-me-My-App-v2")
    }

    // MARK: - OpenCode

    @Test func openCodeStatus() {
        let base = OpenCodeSessions.Row(id: "ses_1", title: "Greeting", slug: "proud-orchid", directory: "/Users/me", updated: 1793878945505,
                                        busy: 1793878943093, idle: 1793878945510, outcome: "succeeded",
                                        model: #"{"id":"gpt-x","providerID":"p"}"#)
        #expect(!OpenCodeSessions.isBusy(base))
        let finished = OpenCodeSessions.session(base, liveDirectories: [])
        #expect(finished.status == .finished && finished.title == "Greeting" && finished.model == "gpt-x" && finished.detail == nil)
        #expect(OpenCodeSessions.session(base, liveDirectories: ["/Users/me"]).status == .idle)

        var busy = base
        busy.busy = 1793878946000
        busy.title = nil
        #expect(OpenCodeSessions.isBusy(busy))
        let running = OpenCodeSessions.session(busy, liveDirectories: [])
        #expect(running.status == .running && running.title == "proud-orchid")
        let waiting = OpenCodeSessions.session(busy, liveDirectories: [], pendingTool: "bash")
        #expect(waiting.status == .waiting && waiting.detail == "bash permission")

        var fresh = base
        fresh.idle = nil
        #expect(OpenCodeSessions.isBusy(fresh))
        fresh.busy = nil
        #expect(!OpenCodeSessions.isBusy(fresh))

        var failed = base
        failed.outcome = "failed"
        #expect(OpenCodeSessions.session(failed, liveDirectories: []).detail == "failed")
    }

    @Test func openCodeMessages() {
        let messages: [(type: String, data: String)] = [
            ("agent-switched", #"{"time":{"created":1},"agent":"build"}"#),
            ("user", #"{"time":{"created":1793922101841},"text":"Whats pivoting?","files":[]}"#),
            ("assistant", ###"{"time":{"created":1793922101852},"content":[{"type":"reasoning","text":"hm"},{"type":"text","text":"Pivoting is…"},{"type":"tool","id":"c1","name":"websearch","state":{"status":"completed","input":{"query":"chisel"},"content":[{"type":"text","text":"## result"}]}},{"type":"tool","id":"c2","name":"bash","state":{"status":"error","input":{"command":"ls /x"},"error":"no such file"}}]}"###),
            ("idle", #"{"time":{"created":1793922108724},"outcome":"succeeded"}"#),
            ("assistant", #"{"content":[{"type":"tool","id":"c3","name":"edit","state":{"status":"pending","input":{"file_path":"/a.txt"}}}]}"#),
        ]
        let (entries, pending) = OpenCodeSessions.entries(messages)
        #expect(entries.map(\.kind) == [.user, .assistant, .tool(name: "websearch"), .result(isError: false), .tool(name: "bash"),
                                        .result(isError: true), .tool(name: "edit")])
        #expect(entries[0].date == Date(timeIntervalSince1970: 1793922101.841))
        #expect(entries[2].text == "chisel" && entries[3].text == "## result" && entries[5].text == "no such file")
        #expect(pending == "edit")
        #expect(OpenCodeSessions.entries(Array(messages.prefix(3))).pendingTool == nil)
    }

    @Test func openCodeDatabaseIsReadOnlyAndTolerant() {
        #expect(OpenCodeSessions.readSessions(since: .distantPast, path: "/nonexistent/opencode.db").isEmpty)
        #expect(OpenCodeSessions.readMessages(session: "x", path: "/nonexistent/opencode.db").isEmpty)
    }

    // MARK: - tmux

    @Test func tmuxPanesMapOntoSessions() {
        let panes = TmuxPane.parse("hop-cc-hop-1a2b|500|1794138000|/Users/me/repos/hop\nwork|600|1794130000|/Users/me\n"
            + "T|hop-oc-api-3c4d|700|1794139000|/Users/me/api\nhop-cc-new-9f9f|800|1794139500|/Users/me/new\nbad line\nx|1|2|/a|b\n")
        #expect(panes.count == 5 && panes[4].path == "/a|b")
        #expect(panes[2] == TmuxPane(session: "hop-oc-api-3c4d", pid: 700, created: Date(timeIntervalSince1970: 1794139000), path: "/Users/me/api"))

        func claude(_ id: String, pid: Int32) -> AgentSession {
            AgentSession(provider: .claude, id: id, host: nil, title: id, cwd: "/x", status: .idle, lastActivity: .distantPast,
                         pid: pid, tmux: nil, bridgeID: nil, transcript: nil, detail: nil, model: nil)
        }
        var oc = claude("ses_1", pid: 0)
        oc.provider = .opencode
        oc.pid = nil
        oc.cwd = "/Users/me/api"
        // 501's parent is the shell tmux started (600): claude run by hand inside tmux.
        // Claude Code reports its own tmux session: that one is claimed without a pane match.
        var reported = claude("c", pid: 900)
        reported.tmux = "hop-cc-new-9f9f"
        let out = AgentStore.attach(panes: Array(panes.prefix(4)), to: [claude("a", pid: 500), claude("b", pid: 501), oc, reported], host: nil,
                                    parent: { $0 == 501 ? 600 : 1 })
        #expect(out.map(\.tmux) == ["hop-cc-hop-1a2b", "work", "hop-oc-api-3c4d", "hop-cc-new-9f9f"])
        let starting = AgentStore.attach(panes: Array(panes.prefix(4)), to: [], host: "my-server")
        #expect(starting.map(\.id) == ["tmux:hop-cc-hop-1a2b", "tmux:hop-oc-api-3c4d", "tmux:hop-cc-new-9f9f"])
        #expect(starting[2].status == .running && starting[2].cwd == "/Users/me/new" && starting[2].host == "my-server")
        #expect(starting[2].lastActivity == Date(timeIntervalSince1970: 1794139500))
    }

    @Test func tmuxNames() {
        #expect(AgentNames.tmuxName(provider: .claude, cwd: "/Users/me/repos/Side Project.v2", suffix: "00ff") == "hop-cc-side-project-v2-00ff")
        #expect(AgentNames.tmuxName(provider: .opencode, cwd: "/", suffix: "1234") == "hop-oc-home-1234")
        #expect(AgentNames.tmuxName(provider: .claude, cwd: "~/čšž", suffix: "abcd") == "hop-cc-home-abcd")
        #expect(AgentNames.provider(ofTmux: "hop-oc-x-1234") == .opencode && AgentNames.provider(ofTmux: "main") == nil)
        #expect(AgentNames.randomSuffix().count == 4)
        let now = Date()
        #expect(AgentNames.age(now, now: now) == "now" && AgentNames.age(now.addingTimeInterval(-600), now: now) == "10m")
        #expect(AgentNames.age(now.addingTimeInterval(-7300), now: now) == "2h" && AgentNames.age(now.addingTimeInterval(-200_000), now: now) == "2d")
    }

    // MARK: - Commands

    @Test func agentCommandLines() {
        var config = HopConfig.Agents()
        config.claude.args = ["--model", "opus"]
        let spawn = AgentCommands.Spawn(provider: .claude, cwd: "~/repos/hop", prompt: "  fix it  ", resume: nil, tmuxName: "hop-cc-hop-1a2b")
        #expect(AgentCommands.agentArguments(spawn, binary: "/bin/claude", config: config)
            == ["/bin/claude", "--model", "opus", "--name", "hop-1a2b", "--remote-control", "hop-1a2b", "fix it"])
        config.claude.remoteControl = false
        var resume = spawn
        resume.resume = "uuid-1"
        resume.prompt = ""
        #expect(AgentCommands.agentArguments(resume, binary: "claude", config: config) == ["claude", "--model", "opus", "--resume", "uuid-1"])

        let oc = AgentCommands.Spawn(provider: .opencode, cwd: "/w", prompt: "hi", resume: "ses_9", tmuxName: "hop-oc-w-0000")
        #expect(AgentCommands.agentArguments(oc, binary: "opencode", config: config) == ["opencode", "--session", "ses_9", "--prompt", "hi"])

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AgentCommands.localTmuxArguments(spawn, agent: ["claude"], path: "/opt/homebrew/bin:/usr/bin")
            == ["new-session", "-d", "-s", "hop-cc-hop-1a2b", "-c", "\(home)/repos/hop", "-e", "PATH=/opt/homebrew/bin:/usr/bin", "--", "claude"])
    }

    @Test func remoteScriptsQuoteForBash() {
        #expect(AgentCommands.quote("it's") == #"'it'\''s'"#)
        #expect(AgentCommands.remotePath("~") == #""$HOME""#)
        #expect(AgentCommands.remotePath("~/apps/my app") == #""$HOME"/'apps/my app'"#)
        #expect(AgentCommands.remotePath("/srv/x") == "'/srv/x'")
        #expect(AgentCommands.sshArguments("my-server").suffix(2) == ["my-server", "bash -l -s"])

        let spawn = AgentCommands.Spawn(provider: .claude, cwd: "~/apps", prompt: "", resume: nil, tmuxName: "hop-cc-apps-1a2b")
        let script = AgentCommands.remoteSpawnScript(spawn, agent: ["claude", "--name", "apps-1a2b", "say \"hi\" it's"])
        #expect(script.hasPrefix(#"cd "$HOME"/'apps' || "#))
        #expect(script.contains(#"tmux new-session -d -s 'hop-cc-apps-1a2b' -c "$PWD" -e "PATH=$PATH" -- 'claude' '--name' 'apps-1a2b' 'say "hi" it'\''s'"#))
        #expect(!script.contains("=x;")) // no VAR=value prefixes for fish to choke on (it runs under bash anyway)

        #expect(AgentCommands.remoteTranscriptScript(sessionID: "abc-1; rm -rf /").contains("/abc-1rm-rf.jsonl"))
        let list = AgentCommands.parseRemoteList("""
            S\t{"pid":42,"sessionId":"r1","cwd":"/home/u/app","kind":"interactive","status":"busy"}
            S\t{"pid":43,"sessionId":"r2","cwd":"/","kind":"daemon"}
            T|hop-cc-app-0001|42|1794139000|/home/u/app
            noise
            """)
        #expect(list.records.map(\.sessionID) == ["r1"] && list.panes.map(\.session) == ["hop-cc-app-0001"])

        #expect(AgentCommands.attachScript(tmux: "/opt/homebrew/bin/tmux", session: "hop-cc-a-1", sshAlias: nil)
            == "#!/bin/bash\nclear\nexec '/opt/homebrew/bin/tmux' attach-session -t '=hop-cc-a-1'\n")
        #expect(AgentCommands.attachScript(tmux: "tmux", session: "hop-cc-a-1", sshAlias: "my-server")
            == "#!/bin/bash\nclear\nexec /usr/bin/ssh -t 'my-server' 'bash -lc \"tmux attach-session -t =hop-cc-a-1\"'\n")
        #expect(AgentCommands.isSafeTmuxName("hop-cc-a-1") && !AgentCommands.isSafeTmuxName("a b") && !AgentCommands.isSafeTmuxName(""))
    }

    // MARK: - Remote Control server mode

    @Test func remoteControlChildIsParsedFromItsArguments() {
        let line = "/Users/me/.local/share/claude/versions/9.9.9 --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_test123 "
            + "--session-id cse_test123 --input-format stream-json --output-format stream-json --replay-user-messages"
        #expect(ClaudeSessions.remoteControlID(commandLine: line) == "cse_test123")
        #expect(ClaudeSessions.remoteControlID(arguments: ["claude", "--print", "--sdk-url=https://example.test/v1/code/sessions/session_test123"])
            == "cse_test123")
        #expect(ClaudeSessions.remoteControlID(commandLine: "claude rc --chrome") == nil)
        #expect(ClaudeSessions.remoteControlID(commandLine: "claude --remote-control my-name") == nil)
        #expect(ClaudeSessions.remoteControlID(arguments: ["claude", "--sdk-url"]) == nil)
        #expect(ClaudeSessions.remoteControlID(sdkURL: "https://example.test/other") == nil)
        #expect(ClaudeSessions.compatSessionID("cse_test123") == "session_test123" && ClaudeSessions.compatSessionID("session_x") == "session_x")
        #expect(ClaudeSessions.infraSessionID("session_test123") == "cse_test123")
    }

    @Test func remoteControlSessionsAreViewOnly() throws {
        let json = #"{"pid":321,"sessionId":"uuid-rc","cwd":"/Users/me/app","kind":"interactive","entrypoint":"sdk-cli","status":"idle","bridgeSessionId":"session_test123"}"#
        let r = try #require(ClaudeSessions.parseRecord(Data(json.utf8)))
        #expect(r.entrypoint == "sdk-cli")

        let rc = ClaudeSessions.session(r, summary: nil, transcript: nil, remoteID: "cse_test123")
        #expect(rc.kind == .remoteControl && rc.remoteID == "cse_test123" && rc.isViewOnly && !rc.isAttachable)
        #expect(rc.webURL == URL(string: "https://claude.ai/code/session_test123") && rc.accessTag == "rc")

        // No command line to read: a driven process with a bridge id and no tmux still counts.
        let fallback = ClaudeSessions.session(r, summary: nil, transcript: nil)
        #expect(fallback.kind == .remoteControl && fallback.remoteID == "cse_test123")

        var bare = rc
        bare.bridgeID = nil
        #expect(bare.webURL == URL(string: "https://claude.ai/code/session_test123"))

        // `claude --remote-control` in tmux: attachable, a terminal session that also has a link.
        let tmuxJSON = #"{"pid":322,"sessionId":"uuid-t","cwd":"/x","entrypoint":"cli","tmux":"hop-cc-x-0001","bridgeSessionId":"session_test456"}"#
        let terminal = ClaudeSessions.session(try #require(ClaudeSessions.parseRecord(Data(tmuxJSON.utf8))), summary: nil, transcript: nil)
        #expect(terminal.kind == .terminal && terminal.remoteID == nil && terminal.isAttachable && !terminal.isViewOnly)
        #expect(terminal.accessTag == "tmux" && terminal.webURL == URL(string: "https://claude.ai/code/session_test456"))

        let plain = #"{"pid":323,"sessionId":"uuid-p","cwd":"/x","entrypoint":"cli","status":"busy"}"#
        let headless = ClaudeSessions.session(try #require(ClaudeSessions.parseRecord(Data(plain.utf8))), summary: nil, transcript: nil)
        #expect(headless.kind == .terminal && headless.isViewOnly && headless.accessTag == "view only" && headless.webURL == nil)
        var done = headless
        done.status = .finished
        #expect(!done.isViewOnly && done.accessTag == nil)
    }

    @Test func remoteListingCarriesRemoteControlIDs() {
        #expect(AgentCommands.remoteListScript.contains("ps -eo pid=,args="))
        let list = AgentCommands.parseRemoteList("""
            S\t{"pid":321,"sessionId":"uuid-rc","cwd":"/home/me/app","kind":"interactive","entrypoint":"sdk-cli","status":"busy"}
            S\t{"pid":322,"sessionId":"uuid-t","cwd":"/home/me","kind":"interactive","entrypoint":"cli"}
            P\t321\thttps://api.anthropic.com/v1/code/sessions/cse_test123
            P\t999\tnot-a-session-url
            P\tx\thttps://api.anthropic.com/v1/code/sessions/cse_bad
            T|hop-cc-home-0001|322|1794139000|/home/me
            """)
        #expect(list.remoteIDs == [321: "cse_test123"])
        let sessions = list.records.map {
            ClaudeSessions.session($0, summary: nil, transcript: nil, host: "my-server", remoteID: list.remoteIDs[$0.pid])
        }
        let out = AgentStore.attach(panes: list.panes, to: sessions, host: "my-server", parent: { _ in nil })
        #expect(out.map(\.kind) == [.remoteControl, .terminal])
        #expect(out[0].remoteID == "cse_test123" && out[0].isViewOnly && out[0].host == "my-server")
        #expect(out[1].tmux == "hop-cc-home-0001" && out[1].isAttachable)
    }

    @Test func remoteListScriptRunsInBash() throws {
        // The script's ps loop prints only pid and --sdk-url value of matching processes.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"a='/bin/claude --print --sdk-url https://example.test/v1/code/sessions/cse_test123 --session-id cse_test123'; "#
            + #"u="${a#*--sdk-url}"; u="${u#=}"; u="${u# }"; u="${u%% *}"; printf 'P\t%s\t%s\n' 42 "$u""#]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(AgentCommands.parseRemoteList(text).remoteIDs == [42: "cse_test123"])
        #expect(AgentCommands.remoteListScript.contains(#"u="${a#*--sdk-url}"; u="${u#=}"; u="${u# }"; u="${u%% *}""#))
    }

    // MARK: - Folder trust

    static let trustScreen = """
         Accessing workspace:

         /Users/me/scratch/new-app

         Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from
         your team). If not, take a moment to review what's in this folder first.

         Claude Code'll be able to read, edit, and execute files here.

         Security guide

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel
        """

    @Test func trustRecordsInClaudeJSON() {
        let json = #"""
        {"numStartups": 3, "projects": {
          "/Users/me/repos": {"allowedTools": [], "hasTrustDialogAccepted": true},
          "/Users/me": {"hasTrustDialogAccepted": false},
          "/Users/me/repos/app": {"allowedTools": [], "lastCost": 0.5},
          "/private/tmp/demo": {"hasTrustDialogAccepted": true, "futureField": {"x": 1}},
          "/weird": "not an object"
        }}
        """#
        let trusted = ClaudeTrust.trustedFolders(claudeJSON: Data(json.utf8))
        #expect(trusted == ["/Users/me/repos", "/private/tmp/demo"])
        #expect(ClaudeTrust.trustedFolders(claudeJSON: Data("{}".utf8)).isEmpty)
        #expect(ClaudeTrust.trustedFolders(claudeJSON: Data("not json".utf8)).isEmpty)

        // The folder itself, or a folder above it outside git.
        #expect(ClaudeTrust.isTrusted(cwd: "/Users/me/repos", gitRoot: nil, trusted: trusted))
        #expect(ClaudeTrust.isTrusted(cwd: "/Users/me/repos/notes/2026", gitRoot: nil, trusted: trusted))
        #expect(!ClaudeTrust.isTrusted(cwd: "/Users/me/other", gitRoot: nil, trusted: trusted))
        #expect(!ClaudeTrust.isTrusted(cwd: "/Users/me", gitRoot: nil, trusted: trusted))
        // A git repository under a trusted folder still asks: only up to its root counts.
        #expect(!ClaudeTrust.isTrusted(cwd: "/Users/me/repos/app/src", gitRoot: "/Users/me/repos/app", trusted: trusted))
        #expect(ClaudeTrust.isTrusted(cwd: "/Users/me/repos/app/src", gitRoot: "/Users/me/repos/app", trusted: trusted.union(["/Users/me/repos/app"])))
        #expect(ClaudeTrust.isTrusted(cwd: "/Users/me/repos/app/src", gitRoot: "/Users/me/repos/app",
                                      trusted: ["/Users/me/repos/app/src"]))
        // A repository whose root is the trusted folder.
        #expect(ClaudeTrust.isTrusted(cwd: "/Users/me/repos/x", gitRoot: "/Users/me/repos", trusted: trusted))
        #expect(!ClaudeTrust.isTrusted(cwd: "/", gitRoot: nil, trusted: trusted))
        #expect(ClaudeTrust.isTrusted(cwd: "/srv/a", gitRoot: nil, trusted: ["/"]))

        let gits: Set<String> = ["/Users/me/repos/app/.git"]
        #expect(ClaudeTrust.gitRoot(of: "/Users/me/repos/app/src/x", exists: gits.contains) == "/Users/me/repos/app")
        #expect(ClaudeTrust.gitRoot(of: "/Users/me/repos/other", exists: gits.contains) == nil)
    }

    @Test func trustQuestionOnScreen() {
        #expect(ClaudeTrust.isPrompt(Self.trustScreen) && !ClaudeTrust.isYesSelected(Self.trustScreen))
        let yes = Self.trustScreen.replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
            .replacingOccurrences(of: "  Yes, I trust", with: "❯ Yes, I trust")
        #expect(ClaudeTrust.isYesSelected(yes))
        #expect(!ClaudeTrust.isPrompt("/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_test123\n> "))
        #expect(!ClaudeTrust.isPrompt("$ echo Yes, I trust this folder"))
    }

    @Test func trustQuestionMarksHopSessions() {
        let panes = TmuxPane.parse("hop-cc-new-0001|500|1794139000|/Users/me/new\nhop-cc-old-0002|501|1794139000|/Users/me/old\n")
        let rows = AgentStore.attach(panes: panes, to: [], host: nil, parent: { _ in nil })
        let out = AgentSession.markTrustPrompts(rows, prompts: ["hop-cc-new-0001"])
        #expect(out[0].needsTrust && out[0].status == .waiting && out[0].detail == "trust folder")
        #expect(!out[1].needsTrust && out[1].status == .running)
        #expect(out.sorted(by: AgentSession.ordered).first?.tmux == "hop-cc-new-0001")

        let list = AgentCommands.parseRemoteList("""
            T|hop-cc-app-0001|42|1794139000|/home/u/app
            Q|hop-cc-app-0001
            Q|bad name; rm
            """)
        #expect(list.trustPrompts == ["hop-cc-app-0001"])
        #expect(AgentCommands.remoteListScript.contains("hop-cc-*") && AgentCommands.remoteListScript.contains("capture-pane -p"))
    }

    /// The confirm script against a stand-in tmux: it moves to Yes, checks, then sends Enter.
    @Test func trustConfirmScript() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let yes = Self.trustScreen.replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
            .replacingOccurrences(of: "  Yes, I trust", with: "❯ Yes, I trust")
        try Self.trustScreen.write(to: dir.appending(path: "screen0"), atomically: true, encoding: .utf8)
        try yes.write(to: dir.appending(path: "screen1"), atomically: true, encoding: .utf8)
        let fake = dir.appending(path: "tmux")
        try """
            #!/bin/bash
            d=\(dir.path)
            echo "$*" >> "$d/log"
            case "$1" in
              capture-pane) n=$(grep -c '^send-keys .* Down$' "$d/log"); [ -f "$d/screen$n" ] && cat "$d/screen$n" || cat "$d/screen1" ;;
            esac
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        func run() throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", ClaudeTrust.confirmScript(tmux: fake.path, session: "hop-cc-new-0001")]
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        #expect(try run() == 0)
        let log = try String(contentsOf: dir.appending(path: "log"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(log.filter { $0.hasPrefix("send-keys") } == ["send-keys -t =hop-cc-new-0001: Down", "send-keys -t =hop-cc-new-0001: Enter"])

        // No question on screen: nothing is sent.
        try FileManager.default.removeItem(at: dir.appending(path: "log"))
        try "/remote-control is active\n".write(to: dir.appending(path: "screen0"), atomically: true, encoding: .utf8)
        #expect(try run() == 6)
        let quiet = try String(contentsOf: dir.appending(path: "log"), encoding: .utf8)
        #expect(!quiet.contains("send-keys"))
    }

    // MARK: - Config

    @Test func agentsConfig() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let d = HopConfig().agents
        #expect(d.enabled && d.hotkey == "shift+cmd+space" && d.defaultProvider == .claude && d.terminal == .auto)
        #expect(d.claude.remoteControl && d.opencode.enabled && d.hosts.isEmpty && d.historyHours == 24)
        #expect(HotkeySpec.parse(d.hotkey) != nil)

        let text = """
        { agents: { hotkey: "hyper+a", defaultProvider: "opencode", terminal: "iterm", historyHours: 6,
          claude: { binary: "~/bin/claude", args: ["--model", "opus"], remoteControl: false },
          hosts: [{ name: "Server", ssh: "my-server", cwd: "~/apps", projects: ["~/apps/web"] }, { ssh: "nas.local" }] } }
        """
        let c = try decoder.decode(HopConfig.self, from: Data(text.utf8)).agents
        #expect(c.hotkey == "hyper+a" && c.defaultProvider == .opencode && c.terminal == .iterm && c.historyHours == 6)
        #expect(c.claude.binary == "~/bin/claude" && c.claude.args == ["--model", "opus"] && !c.claude.remoteControl && c.claude.enabled)
        #expect(c.opencode == HopConfig.Agents().opencode)
        #expect(c.hosts.map(\.label) == ["Server", "nas.local"] && c.hosts[1].cwd == "~" && c.hosts[1].claude == "claude")
        #expect(c.hosts[0].projects == ["~/apps/web"])

        let template = try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8))
        #expect(template.agents == HopConfig.Agents())

        #expect(ConfigSchema.hop.node(at: ["agents", "terminal"]) == .choice(["auto", "ghostty", "iterm", "terminal"]))
        #expect(ConfigSchema.hop.node(at: ["agents", "defaultProvider"]) == .choice(["claude", "opencode"]))
        let warnings = ConfigDiagnostics.warnings(in: "{ agents: { hosts: [{ ssh: 'a', sshh: 'b' }], clade: {} } }").map(\.message)
        #expect(warnings == ["agents.hosts[0].sshh (line 1): unknown key, did you mean ssh?", "agents.clade (line 1): unknown key, did you mean claude?"])
        do {
            _ = try decoder.decode(HopConfig.self, from: Data("{ agents: { terminal: 'kitty' } }".utf8))
            Issue.record("kitty should not decode")
        } catch {
            #expect(ConfigDiagnostics.issue(for: error, in: "{ agents: { terminal: 'kitty' } }").message
                == #"agents.terminal (line 1): "kitty" is not one of auto, ghostty, iterm, terminal"#)
        }
    }
}

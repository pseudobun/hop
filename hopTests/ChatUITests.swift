import AppKit
import Foundation
import Testing
@testable import hop

/// The chat UI's pure parts: list rows for chats, de-duplication, permission modes, the
/// transcript as chat rows, Markdown, composer keys, grouping and filters.
struct ChatUITests {
    private static func session(_ id: String, provider: AgentProvider = .claude, host: String? = nil, status: AgentStatus = .idle,
                                cwd: String = "/Users/me/repos/hop", age: Double = 0) -> AgentSession {
        AgentSession(provider: provider, id: id, host: host, title: id, cwd: cwd, status: status,
                     lastActivity: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    private static func approval(_ id: String = "r1", options: [ChatDecision] = [.allow, .deny]) -> ChatApproval {
        ChatApproval(id: id, kind: .tool, title: "Bash", detail: "ls", options: options)
    }

    // MARK: - Rows

    @Test func statusMapsToListSections() {
        #expect(ChatRows.status(.waitingForApproval) == .waiting)
        #expect(ChatRows.status(.running) == .running)
        #expect(ChatRows.status(.starting) == .running)
        #expect(ChatRows.status(.idle) == .idle)
        #expect(ChatRows.status(.ended) == .finished)
        #expect(ChatRows.status(.failed) == .finished)
    }

    @Test func chatRowFromState() {
        var state = ChatState()
        state.phase = .running
        state.items = [ChatItem(id: "u", kind: .user, text: "hi"), ChatItem(id: "t", kind: .tool, text: "ls", name: "Bash", status: .running)]
        var row = ChatRows.session(id: "chat:1", provider: .codex, host: "olympus", title: "hi", cwd: "~/x", state: state, lastActivity: Date())
        #expect(row.status == .running && row.detail == "Bash" && row.kind == .chat && row.accessTag == "chat")
        #expect(!row.isViewOnly && row.key == "olympus/codex/chat:1")
        state.addApproval(Self.approval())
        row = ChatRows.session(id: "chat:1", provider: .codex, host: nil, title: "hi", cwd: "~/x", state: state, lastActivity: Date())
        #expect(row.status == .waiting && row.detail == "Bash approval")
        state.phase = .failed
        state.cancelPendingApprovals()
        #expect(ChatRows.detail(state) == "failed")
    }

    @Test func mergeDropsTheObservedCopyOfAChat() {
        let chat = ChatRows.session(id: "chat:1", provider: .claude, host: nil, title: "t", cwd: "/x", state: ChatState(), lastActivity: Date())
        let observed = [Self.session("abc"), Self.session("abc", host: "olympus"), Self.session("old", status: .finished),
                        Self.session("abc", provider: .codex)]
        let merged = ChatRows.merge(chats: [(chat, ["abc", "old"])], observed: observed)
        #expect(merged.map(\.key).sorted() == ["local/claude/chat:1", "local/codex/abc", "olympus/claude/abc"].sorted())
        // Ordered like the list: running (starting) before idle.
        #expect(merged.first?.id == "chat:1")
    }

    @Test func permissionModesMapOneToOne() {
        #expect(AgentPermissionMode.allCases.map(ChatRows.permissionMode) == [.ask, .acceptEdits, .auto, .bypass])
        #expect(AgentPermissionMode.allCases.map(\.label) == ["Supervised", "Auto-accept edits", "Auto", "Full access"])
        #expect([ChatPermissionMode.ask, .acceptEdits, .auto, .bypass].map(\.label) == ["Supervised", "Auto-accept edits", "Auto", "Full access"])
        #expect([ChatPermissionMode.ask, .acceptEdits, .auto, .plan, .bypass].map(ChatClaude.permissionMode)
            == ["default", "acceptEdits", "auto", "plan", "bypassPermissions"])
        #expect(ChatCodex.policy(.auto) == ("on-request", "workspace-write"))
        // The terminal path: OpenCode has no reviewer, so Auto adds nothing.
        #expect(AgentPermissionMode.auto.arguments(for: .opencode).isEmpty)
        #expect(AgentPermissionMode.full.arguments(for: .opencode) == ["--auto"])
    }

    @Test func providersTitlesAndModels() {
        #expect(ChatRows.chatProvider(.claude) == .claude && ChatRows.chatProvider(.codex) == .codex)
        #expect(ChatRows.chatProvider(.opencode) == nil && ChatRows.chatProvider(.cursor) == nil)
        #expect(ChatRows.title(prompt: "  fix the test\nand more", fallback: "x") == "fix the test")
        #expect(ChatRows.title(prompt: " \n", fallback: "New chat") == "New chat")
        #expect(ChatRows.title(prompt: String(repeating: "a", count: 100), fallback: "").count == 80)
        #expect(ChatRows.model(["--model", "opus"]) == "opus")
        #expect(ChatRows.model(["-m", "o3", "--x"]) == "o3")
        #expect(ChatRows.model(["--model=haiku"]) == "haiku")
        #expect(ChatRows.model(["--verbose"]) == nil)
    }

    @Test func continueInChatOnlyOutsideATerminal() {
        #expect(ChatRows.canContinue(Self.session("a", status: .finished)))
        #expect(ChatRows.canContinue(Self.session("a", status: .idle)))
        #expect(!ChatRows.canContinue(Self.session("a", status: .running)))
        var tmux = Self.session("a", status: .idle)
        tmux.tmux = "hop-cc-x-1234"
        #expect(!ChatRows.canContinue(tmux))
        #expect(!ChatRows.canContinue(Self.session("tmux:hop-cc-x", status: .finished)))
        #expect(!ChatRows.canContinue(Self.session("a", provider: .opencode, status: .finished)))
        #expect(ChatRows.canContinue(Self.session("a", host: "olympus", status: .finished)))
        // Remote Codex rollouts are not read, so there is nothing to continue from.
        #expect(!ChatRows.canContinue(Self.session("a", provider: .codex, host: "olympus", status: .finished)))
    }

    // MARK: - History

    @Test func transcriptBecomesChatRows() {
        let entries = [
            TranscriptEntry(kind: .user, text: "go", date: nil),
            TranscriptEntry(kind: .tool(name: "Bash"), text: "ls", date: nil),
            TranscriptEntry(kind: .result(isError: false), text: "a\nb", date: nil),
            TranscriptEntry(kind: .tool(name: "Edit"), text: "x.swift", date: nil, diff: "-a\n+b"),
            TranscriptEntry(kind: .result(isError: true), text: "nope", date: nil),
            TranscriptEntry(kind: .assistant, text: "done", date: nil),
            TranscriptEntry(kind: .tool(name: "Read"), text: "y", date: nil),
        ]
        let running = ChatRows.items(entries, running: true)
        #expect(running.map(\.kind) == [.user, .tool, .fileChange, .assistant, .tool])
        #expect(running[1].status == .done && running[1].output == "a\nb")
        #expect(running[2].status == .failed && running[2].diff == "-a\n+b" && running[2].path == "x.swift")
        #expect(running[4].status == .running)
        #expect(ChatRows.items(entries, running: false)[4].status == .done)
        #expect(ChatRows.history(Array(repeating: entries[0], count: 100)).count == 80)
    }

    @Test func historyIsDimmedAndMarked() {
        let h = ChatRender.history([TranscriptEntry(kind: .user, text: "earlier", date: nil)], provider: .claude)
        #expect(h.string.contains("earlier") && h.string.hasSuffix("— continued in hop —\n\n"))
        let color = h.attribute(.foregroundColor, at: h.string.distance(from: h.string.startIndex, to: h.string.range(of: "earlier")!.lowerBound),
                                effectiveRange: nil) as? NSColor
        #expect((color?.alphaComponent ?? 1) < 0.6)
        #expect(ChatRender.history([], provider: .claude).length == 0)
    }

    // MARK: - Markdown

    @Test func markdownSegments() {
        typealias S = ChatMarkdown.Segment
        #expect(ChatMarkdown.segments("run `just test` now") == [S.text("run "), .code("just test"), .text(" now")])
        #expect(ChatMarkdown.segments("a **b** c") == [S.text("a "), .bold("b"), .text(" c")])
        #expect(ChatMarkdown.segments("# Title\nbody") == [S.heading("Title"), .text("\nbody")])
        #expect(ChatMarkdown.segments("#hashtag") == [S.text("#hashtag")])
        #expect(ChatMarkdown.segments("x\n```swift\nlet a = 1\n```\ny") == [S.text("x"), .block("let a = 1"), .text("y")])
        // Still streaming: the open fence is a block so far.
        #expect(ChatMarkdown.segments("```\npartial") == [S.block("partial")])
        #expect(ChatMarkdown.segments("a `b") == [S.text("a `b")])
    }

    @Test func renderedItemsUseMonoForCode() {
        let r = ChatRender.markdown("use `x`")
        let font = r.attribute(.font, at: r.length - 1, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true || font?.fontName.lowercased().contains("mono") == true)
        let tool = ChatRender.item(ChatItem(id: "t", kind: .tool, text: "ls -la", name: "Bash", status: .failed, output: "1\n2\n3\n4\n5\n6"),
                                   speaker: "Claude")
        #expect(tool.string.hasPrefix("✗ Bash  ls -la\n") && tool.string.contains("… 2 more lines\n3\n4\n5\n6"))
        var item = ChatItem(id: "a", kind: .approval, text: "ls", name: "Bash", status: .running)
        item.approval = Self.approval(options: [.allow, .allowAlways, .deny])
        #expect(ChatRender.item(item, speaker: "Claude").string.contains("⌘⇧Y always"))
    }

    // MARK: - Composer keys

    @Test func composerKeys() {
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], _ c: String? = nil) -> ChatComposerKey? {
            ChatComposerKey.action(keyCode: code, modifiers: mods, characters: c)
        }
        #expect(key(36) == .send && key(76) == .send)
        #expect(key(36, .shift) == .newline && key(36, .option) == .newline)
        #expect(key(48) == .leave && key(53) == .leave && key(37, .command, "l") == .leave)
        #expect(key(8, .control, "c") == .interrupt && key(47, .command, ".") == .interrupt)
        #expect(key(8, .command, "c") == nil && key(0, [], "a") == nil && key(36, .command) == nil)
        // Caps Lock and the like do not count.
        #expect(key(36, [.capsLock]) == .send)
    }

    // MARK: - Grouping and filters

    @Test func groupsByEachKey() {
        let all = [Self.session("a", status: .finished, cwd: "/r/hop"), Self.session("b", host: "olympus", status: .waiting, cwd: "~/x"),
                   Self.session("c", provider: .codex, status: .running, cwd: "/Users/me/.hop-worktrees/hop/fix-1"),
                   Self.session("d", host: "zeus", status: .idle, cwd: "/srv/app")]
        func titles(_ g: AgentGrouping.GroupBy) -> [String] { AgentGrouping.sections(all, by: g, hosts: ["zeus", "olympus"]).map(\.title) }
        #expect(titles(.status) == ["Needs you", "Running", "Idle", "Finished"])
        #expect(titles(.environment) == ["This Mac", "zeus", "olympus"])
        #expect(titles(.project) == ["app", "hop", "x"])
        #expect(titles(.provider) == ["Claude Code", "Codex"])
        let env = AgentGrouping.sections(all, by: .environment, hosts: ["zeus", "olympus"])
        #expect(env[0].sessions.map(\.id) == ["c", "a"]) // status order inside
        #expect(AgentGrouping.environments(hosts: [], sessions: all) == ["This Mac", "olympus", "zeus"])
    }

    @Test func filtersCombine() {
        let s = [Self.session("a"), Self.session("b", host: "olympus", status: .waiting), Self.session("c", host: "olympus")]
        var f = AgentGrouping.Filter()
        #expect(f.isEmpty && s.filter(f.matches).count == 3)
        f.environment = "olympus"
        #expect(s.filter(f.matches).map(\.id) == ["b", "c"])
        f.status = .waiting
        #expect(s.filter(f.matches).map(\.id) == ["b"] && f.label == "olympus · Needs you")
        f.environment = "This Mac"
        #expect(s.filter(f.matches).isEmpty)
    }
}

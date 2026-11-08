import Foundation

/// Shell and tmux command lines for watching, starting and attaching agents. Remote hosts
/// get a bash script on stdin (`ssh host bash -l -s`), so the login shell there (often
/// fish) never parses it.
nonisolated enum AgentCommands {
    /// Single-quoted for bash.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A path for a bash script: a leading `~` stays expandable.
    static func remotePath(_ path: String) -> String {
        if path == "~" || path.isEmpty { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    /// ssh arguments that run a bash script from stdin as a login shell.
    static func sshArguments(_ alias: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", alias, "bash -l -s"]
    }

    // MARK: - Starting

    struct Spawn: Equatable, Sendable {
        var provider: AgentProvider
        var cwd: String
        var prompt: String
        /// Continue this session instead of starting a new one.
        var resume: String?
        var tmuxName: String
        var mode: AgentPermissionMode = .supervised
        /// Start in a new git worktree of `cwd` by this name (branch hop/<name>).
        var worktree: String? = nil
    }

    /// The agent's own command: binary, configured flags, permission mode, then name / resume / prompt.
    static func agentArguments(_ s: Spawn, binary: String, config: HopConfig.Agents) -> [String] {
        var args = [binary]
        let prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = s.mode.arguments(for: s.provider)
        switch s.provider {
        case .claude:
            args += config.claude.args + mode
            let label = String(s.tmuxName.dropFirst("hop-cc-".count))
            if let resume = s.resume {
                args += ["--resume", resume]
            } else {
                args += ["--name", label]
            }
            // --remote-control takes an optional name, so it always gets one: a prompt after
            // it would be read as the name.
            if config.claude.remoteControl { args += ["--remote-control", label] }
            if !prompt.isEmpty { args += [prompt] }
        case .opencode:
            args += config.opencode.args + mode
            if let resume = s.resume { args += ["--session", resume] }
            if !prompt.isEmpty { args += ["--prompt", prompt] }
        case .codex:
            // `codex resume` takes the same flags as `codex`; the id and the prompt are positional.
            if s.resume != nil { args.append("resume") }
            args += config.codex.args + mode
            if let resume = s.resume { args.append(resume) }
            if !prompt.isEmpty { args.append(prompt) }
        case .cursor:
            args += config.cursor.args + mode
            if let resume = s.resume { args += ["--resume", resume] }
            if !prompt.isEmpty { args.append(prompt) }
        }
        return args
    }

    // MARK: - Worktrees

    /// Bash run in the chosen folder: a new git worktree for `name` on branch hop/<name>, from
    /// what is checked out there (kept in `branch.hop/<name>.hopBase` for Show Changes), and a
    /// `cd` into it at the same subfolder. `root`: `agents.worktreeRoot`.
    static func worktreeLines(name: String, root: String) -> String {
        let safe = String(name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(48))
        let dest = root.hasPrefix("/") || root.hasPrefix("~") || root.isEmpty
            ? "\(remotePath(root.isEmpty ? "~/.hop-worktrees" : root))/\"$(basename \"$top\")\"/\(quote(safe))"
            : "\"$top\"/\(quote(root))/\(quote(safe))"
        return """
            top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repository: $PWD" >&2; exit 8; }
            rel=$(git rev-parse --show-prefix 2>/dev/null)
            base=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null)
            wt=\(dest)
            mkdir -p "$(dirname "$wt")" || exit 8
            out=$(git worktree add -b \(quote("hop/" + safe)) "$wt" 2>&1) || { printf '%s\\n' "$out" | tail -1 >&2; exit 8; }
            [ -n "$base" ] && git config \(quote("branch.hop/\(safe).hopBase")) "$base"
            cd "$wt/$rel" 2>/dev/null || cd "$wt" || exit 8
            """
    }

    /// The worktree lines for a spawn that asks for one, else nothing.
    static func worktreePrefix(_ s: Spawn, config: HopConfig.Agents) -> String {
        guard let name = s.worktree, !name.isEmpty else { return "" }
        return worktreeLines(name: name, root: config.worktreeRoot) + "\n"
    }

    /// Bash for this Mac: make the worktree and print where the agent should start.
    static func localWorktreeScript(_ s: Spawn, config: HopConfig.Agents) -> String {
        "\(remoteCdLine(Spawn(provider: s.provider, cwd: s.cwd.expandingTilde, prompt: "", resume: nil, tmuxName: "")))\n"
            + worktreePrefix(s, config: config) + "pwd\n"
    }

    // MARK: - Changes

    /// Bash that prints a folder's branch ("B|branch|base"), `git status --short` ("S|…"), then
    /// after "D|" the diff: against the fork point for a hop worktree branch, else HEAD.
    static func diffScript(cwd: String) -> String {
        """
        cd \(remotePath(cwd)) 2>/dev/null || { echo "no such folder: \(cwd.replacingOccurrences(of: "\"", with: ""))" >&2; exit 3; }
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 4; }
        b=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
        base=""; from=HEAD
        if [ -n "$b" ]; then base=$(git config --get "branch.$b.hopBase" 2>/dev/null); fi
        if [ -n "$base" ]; then f=$(git merge-base HEAD "$base" 2>/dev/null) && from=$f; fi
        printf 'B|%s|%s\\n' "${b:-detached}" "$base"
        git status --short 2>/dev/null | head -400 | sed 's/^/S|/'
        echo 'D|'
        git -c core.quotepath=off diff --no-color --no-ext-diff "$from" 2>/dev/null | head -c 800000
        exit 0
        """
    }

    /// `tmux new-session` arguments for this Mac (the command runs directly, no shell).
    static func localTmuxArguments(_ s: Spawn, agent: [String], path: String?) -> [String] {
        var args = ["new-session", "-d", "-s", s.tmuxName, "-c", s.cwd.expandingTilde]
        if let path, !path.isEmpty { args += ["-e", "PATH=\(path)"] }
        return args + ["--"] + agent
    }

    /// Bash for a remote host: cd, check tmux, start the session with the login PATH.
    static func remoteSpawnScript(_ s: Spawn, agent: [String], config: HopConfig.Agents = HopConfig.Agents()) -> String {
        """
        \(remoteCdLine(s))
        \(worktreePrefix(s, config: config))command -v tmux >/dev/null 2>&1 || { echo "tmux is not installed" >&2; exit 4; }
        \(remoteAgentCheckLine(agent))
        \(remoteTmuxLine(s, agent: agent))
        """
    }

    /// The same in herdr, with tmux as the fallback.
    static func remoteHerdrSpawnScript(_ s: Spawn, agent: [String], herdr: String, config: HopConfig.Agents = HopConfig.Agents()) -> String {
        """
        \(remoteCdLine(s))
        \(worktreePrefix(s, config: config))\(Herdr.spawnScript(herdr: herdr, name: s.tmuxName, kind: s.provider.herdrKind,
                            agentArgs: Herdr.agentStartArguments(agent),
                            tmuxFallback: remoteAgentCheckLine(agent) + "\n  " + remoteTmuxLine(s, agent: agent)))
        """
    }

    static func remoteCdLine(_ s: Spawn) -> String {
        "cd \(remotePath(s.cwd)) || { echo \"no such folder: \(s.cwd.replacingOccurrences(of: "\"", with: ""))\" >&2; exit 3; }"
    }

    static func remoteAgentCheckLine(_ agent: [String]) -> String {
        "command -v \(quote(agent[0])) >/dev/null 2>&1 || { echo \"\(agent[0].replacingOccurrences(of: "\"", with: "")) not found\" >&2; exit 5; }"
    }

    static func remoteTmuxLine(_ s: Spawn, agent: [String]) -> String {
        "tmux new-session -d -s \(quote(s.tmuxName)) -c \"$PWD\" -e \"PATH=$PATH\" -- \(agent.map(quote).joined(separator: " "))"
    }

    // MARK: - Watching remote hosts

    /// The listing with herdr's snapshot too, when herdr is there (`herdr`: its command).
    static func remoteListScript(herdr: String?) -> String {
        guard let herdr, !herdr.isEmpty else { return remoteListScript }
        return remoteListScript.replacingOccurrences(of: "\nexit 0", with: "\n" + Herdr.remoteListLines(herdr: herdr) + "\nexit 0")
    }

    /// Live Claude Code sessions (registry records of running processes), the `--sdk-url` of
    /// `claude rc` children (pid and URL only, no other arguments) and tmux panes.
    static let remoteListScript = """
        for f in "$HOME"/.claude/sessions/*.json; do
          [ -f "$f" ] || continue
          p="${f##*/}"; p="${p%.json}"
          case "$p" in *[!0-9]*) continue ;; esac
          kill -0 "$p" 2>/dev/null || continue
          printf 'S\\t'; tr -d '\\n' < "$f"; echo
        done
        ps -eo pid=,args= 2>/dev/null | while read -r p a; do
          case "$a" in *--sdk-url*) ;; *) continue ;; esac
          u="${a#*--sdk-url}"; u="${u#=}"; u="${u# }"; u="${u%% *}"
          printf 'P\\t%s\\t%s\\n' "$p" "$u"
        done
        if command -v tmux >/dev/null 2>&1; then
          tmux list-panes -a -F 'T|\(TmuxPane.format)' 2>/dev/null
          tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r n; do
            case "$n" in hop-cc-*) ;; *) continue ;; esac
            tmux capture-pane -p -t "=$n:" 2>/dev/null | grep -q '\(ClaudeTrust.yesOption)' && printf 'Q|%s\\n' "$n"
          done
        fi
        exit 0
        """

    /// The tail of one remote transcript.
    static func remoteTranscriptScript(sessionID: String) -> String {
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
            for f in "$HOME"/.claude/projects/*/\(safe).jsonl; do
              [ -f "$f" ] && tail -c 262144 "$f" && exit 0
            done
            exit 0
            """
    }

    struct RemoteList: Equatable, Sendable {
        var records: [ClaudeSessions.Record] = []
        var panes: [TmuxPane] = []
        /// claude.ai session ("cse_…") of each `claude rc` child, by pid.
        var remoteIDs: [Int32: String] = [:]
        /// hop tmux sessions (and "herdr:<agent>") where Claude Code asks whether to trust the folder.
        var trustPrompts: Set<String> = []
        /// herdr's snapshot on the host, when it runs there.
        var herdr: Herdr.Snapshot?
    }

    static func parseRemoteList(_ text: String) -> RemoteList {
        var out = RemoteList()
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("S\t") {
                if let r = ClaudeSessions.parseRecord(Data(line.dropFirst(2).utf8)), r.kind != "daemon" { out.records.append(r) }
            } else if line.hasPrefix("P\t") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                if parts.count == 3, let pid = Int32(parts[1]), let id = ClaudeSessions.remoteControlID(sdkURL: parts[2]) {
                    out.remoteIDs[pid] = id
                }
            } else if line.hasPrefix("Q|") {
                let name = String(line.dropFirst(2))
                let bare = name.hasPrefix("herdr:") ? String(name.dropFirst(6)) : name
                if isSafeTmuxName(bare) { out.trustPrompts.insert(name) }
            } else if line.hasPrefix("H\t") {
                out.herdr = Herdr.parseSnapshot(Data(line.dropFirst(2).utf8))
            } else if line.hasPrefix("T|") {
                out.panes += TmuxPane.parse(String(line))
            }
        }
        return out
    }

    // MARK: - Attaching

    /// A `.command` script that attaches a terminal to the tmux session.
    static func attachScript(tmux: String, session: String, sshAlias: String?) -> String {
        let target = quote("=" + session)
        if let sshAlias {
            // The remote login shell parses this one line: bash -lc keeps it shell-neutral.
            let remote = "bash -lc \"tmux attach-session -t =\(session)\""
            return "#!/bin/bash\nclear\nexec /usr/bin/ssh -t \(quote(sshAlias)) \(quote(remote))\n"
        }
        return "#!/bin/bash\nclear\nexec \(quote(tmux)) attach-session -t \(target)\n"
    }

    /// A `.command` script that attaches a terminal to an agent in herdr.
    static func herdrAttachScript(herdr: String, pane: String, sshAlias: String?) -> String {
        if let sshAlias {
            let remote = "bash -lc \"\(herdr) agent attach \(pane)\""
            return "#!/bin/bash\nclear\nexec /usr/bin/ssh -t \(quote(sshAlias)) \(quote(remote))\n"
        }
        return "#!/bin/bash\nclear\nexec \(quote(herdr)) agent attach \(quote(pane))\n"
    }

    /// Only names hop could have made: letters, digits and dashes.
    static func isSafeTmuxName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

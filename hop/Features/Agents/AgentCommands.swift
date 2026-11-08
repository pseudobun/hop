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
    }

    /// The agent's own command: binary, configured flags, then name / resume / prompt.
    static func agentArguments(_ s: Spawn, binary: String, config: HopConfig.Agents) -> [String] {
        var args = [binary]
        let prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch s.provider {
        case .claude:
            args += config.claude.args
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
            args += config.opencode.args
            if let resume = s.resume { args += ["--session", resume] }
            if !prompt.isEmpty { args += ["--prompt", prompt] }
        }
        return args
    }

    /// `tmux new-session` arguments for this Mac (the command runs directly, no shell).
    static func localTmuxArguments(_ s: Spawn, agent: [String], path: String?) -> [String] {
        var args = ["new-session", "-d", "-s", s.tmuxName, "-c", s.cwd.expandingTilde]
        if let path, !path.isEmpty { args += ["-e", "PATH=\(path)"] }
        return args + ["--"] + agent
    }

    /// Bash for a remote host: cd, check tmux, start the session with the login PATH.
    static func remoteSpawnScript(_ s: Spawn, agent: [String]) -> String {
        """
        cd \(remotePath(s.cwd)) || { echo "no such folder: \(s.cwd.replacingOccurrences(of: "\"", with: ""))" >&2; exit 3; }
        command -v tmux >/dev/null 2>&1 || { echo "tmux is not installed" >&2; exit 4; }
        command -v \(quote(agent[0])) >/dev/null 2>&1 || { echo "\(agent[0].replacingOccurrences(of: "\"", with: "")) not found" >&2; exit 5; }
        tmux new-session -d -s \(quote(s.tmuxName)) -c "$PWD" -e "PATH=$PATH" -- \(agent.map(quote).joined(separator: " "))
        """
    }

    // MARK: - Watching remote hosts

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
        command -v tmux >/dev/null 2>&1 && tmux list-panes -a -F 'T|\(TmuxPane.format)' 2>/dev/null
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

    /// Only names hop could have made: letters, digits and dashes.
    static func isSafeTmuxName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

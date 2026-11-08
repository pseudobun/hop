import AppKit

/// Starts agents in tmux or herdr (here or over SSH) and opens a terminal attached to one.
enum AgentLauncher {
    struct Started {
        /// Why it did not start; nil when it did.
        var error: String?
        /// Why herdr was asked for but tmux took it.
        var fallback: String?
        var herdr = false
    }

    /// Starts `spawn` in what `agents.multiplexer` (or the host's) asks for.
    static func start(_ spawn: AgentCommands.Spawn, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> Started {
        var spawn = spawn
        if host == nil, spawn.worktree != nil {
            switch await makeLocalWorktree(spawn, config: config) {
            case .success(let path):
                spawn.cwd = path
                spawn.worktree = nil
            case .failure(let f):
                return Started(error: f.text)
            }
        }
        guard config.multiplexer(for: host) == .herdr else { return Started(error: await startTmux(spawn, host: host, config: config)) }
        if let host {
            let agent = AgentCommands.agentArguments(spawn, binary: host.binary(for: spawn.provider), config: config)
            guard Herdr.isValidName(spawn.tmuxName) else { return Started(error: "“\(spawn.tmuxName)” is not a name herdr takes") }
            let script = AgentCommands.remoteHerdrSpawnScript(spawn, agent: agent, herdr: host.herdr.isEmpty ? "herdr" : host.herdr, config: config)
            guard let r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: Data(script.utf8),
                                                       timeout: .seconds(40)) else { return Started(error: "ssh could not start") }
            let fallback = r.out.split(whereSeparator: \.isNewline).first { $0.hasPrefix("fallback: ") }.map { String($0.dropFirst(10)) }
            guard r.ok else {
                return Started(error: r.err.split(whereSeparator: \.isNewline).last.map { Herdr.errorMessage(String($0)) } ?? "ssh exited with \(r.status)",
                               fallback: fallback)
            }
            return Started(error: nil, fallback: fallback, herdr: fallback == nil)
        }
        guard let herdr = AgentTools.herdr(config) else {
            return Started(error: await startTmux(spawn, host: nil, config: config), fallback: "herdr is not installed")
        }
        guard let snap = await AgentStore.herdrSnapshot(herdr) else {
            return Started(error: await startTmux(spawn, host: nil, config: config), fallback: "the herdr server is not running")
        }
        guard snap.isCompatible else {
            return Started(error: await startTmux(spawn, host: nil, config: config),
                           fallback: "herdr speaks protocol \(snap.proto), hop knows \(Herdr.knownProtocol)")
        }
        return Started(error: await startHerdr(spawn, herdr: herdr, config: config), herdr: true)
    }

    /// A new herdr workspace labelled like the agent, and the agent started in its pane.
    private static func startHerdr(_ spawn: AgentCommands.Spawn, herdr: String, config: HopConfig.Agents) async -> String? {
        guard Herdr.isValidName(spawn.tmuxName) else { return "“\(spawn.tmuxName)” is not a name herdr takes" }
        var isDir: ObjCBool = false
        let cwd = spawn.cwd.expandingTilde
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return "No folder \(spawn.cwd)" }
        guard let ws = try? await ProcessRunner.run(herdr, ["workspace", "create", "--cwd", cwd, "--label", spawn.tmuxName, "--no-focus"],
                                                    timeout: .seconds(10)) else { return "herdr could not start" }
        guard ws.ok, let pane = Herdr.rootPane(ws.stdout) else { return Herdr.errorMessage(ws.err + ws.out) }
        // herdr starts its own `claude` / `opencode`; the arguments follow `--`.
        let agent = Herdr.agentStartArguments(AgentCommands.agentArguments(spawn, binary: spawn.provider.rawValue, config: config))
        let args = ["agent", "start", spawn.tmuxName, "--kind", spawn.provider.herdrKind, "--pane", pane,
                    "--timeout", "20000", "--"] + agent
        guard let r = try? await ProcessRunner.run(herdr, args, timeout: .seconds(30)) else { return "herdr agent start did not answer" }
        // Blocked at startup (Claude's trust question, say) still started it: the panel shows why.
        if r.ok || (r.err + r.out).contains("agent_not_ready") { return nil }
        return Herdr.errorMessage(r.err + r.out)
    }

    /// Starts `spawn` in tmux; returns an error message, or nil when tmux took it.
    static func startTmux(_ spawn: AgentCommands.Spawn, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> String? {
        if let host {
            let agent = AgentCommands.agentArguments(spawn, binary: host.binary(for: spawn.provider), config: config)
            let script = AgentCommands.remoteSpawnScript(spawn, agent: agent, config: config)
            guard let r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: Data(script.utf8),
                                                       timeout: .seconds(20)) else { return "ssh could not start" }
            return r.ok ? nil : (r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh exited with \(r.status)")
        }
        guard let tmux = AgentTools.tmux(config) else { return "tmux not found: brew install tmux, or set agents.tmux" }
        let path = await AgentTools.loginPath()
        guard let binary = AgentTools.binary(spawn.provider, config, path: path) else {
            return "\(spawn.provider.label) not found: set agents.\(spawn.provider.rawValue).binary"
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spawn.cwd.expandingTilde, isDirectory: &isDir), isDir.boolValue else {
            return "No folder \(spawn.cwd)"
        }
        let agent = AgentCommands.agentArguments(spawn, binary: binary, config: config)
        let args = AgentCommands.localTmuxArguments(spawn, agent: agent, path: path)
        guard let r = try? await ProcessRunner.run(tmux, args, timeout: .seconds(10)) else { return "tmux could not start" }
        return r.ok ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated struct Failure: Error { let text: String }

    /// A new git worktree of the spawn's folder on this Mac; its path (at the same subfolder).
    static func makeLocalWorktree(_ spawn: AgentCommands.Spawn, config: HopConfig.Agents) async -> Result<String, Failure> {
        let path = await AgentTools.loginPath()
        let env = ["PATH": path, "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        guard let r = try? await ProcessRunner.run("/bin/bash", ["-s"], stdin: Data(AgentCommands.localWorktreeScript(spawn, config: config).utf8),
                                                   environment: env, timeout: .seconds(30))
        else { return .failure(Failure(text: "git could not start")) }
        let last = r.out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard r.ok, last.hasPrefix("/") else {
            return .failure(Failure(text: r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "git worktree failed (\(r.status))"))
        }
        return .success(last)
    }

    /// `git status` and the diff of a session's folder, here or over ssh (`AgentCommands.diffScript`).
    static func changes(cwd: String, host: HopConfig.Agents.Host?) async -> Result<GitChanges, Failure> {
        let script = Data(AgentCommands.diffScript(cwd: cwd).utf8)
        let r: ProcessResult?
        if let host {
            r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: script, timeout: .seconds(20))
        } else {
            let env = ["PATH": await AgentTools.loginPath(), "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            r = try? await ProcessRunner.run("/bin/bash", ["-s"], stdin: script, environment: env, timeout: .seconds(15))
        }
        guard let r else { return .failure(Failure(text: host == nil ? "git could not start" : "ssh could not start")) }
        guard r.ok else { return .failure(Failure(text: r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.status)")) }
        return .success(GitChanges.parse(r.out))
    }

    /// Ends a tmux session hop started.
    static func stop(tmux name: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> String? {
        guard AgentCommands.isSafeTmuxName(name) else { return "Not a session hop can stop" }
        let r: ProcessResult?
        if let host {
            r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh),
                                             stdin: Data("tmux kill-session -t \(AgentCommands.quote("=" + name))\n".utf8),
                                             timeout: .seconds(12))
        } else {
            guard let tmux = AgentTools.tmux(config) else { return "tmux not found" }
            r = try? await ProcessRunner.run(tmux, ["kill-session", "-t", "=" + name], timeout: .seconds(5))
        }
        guard let r else { return "Could not run tmux" }
        return r.ok ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Closes the herdr workspace hop made for an agent, and the agent in it.
    static func stop(herdrWorkspace ws: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> String? {
        guard Herdr.isSafeID(ws) else { return "Not a workspace hop can close" }
        let r: ProcessResult?
        if let host {
            let h = AgentCommands.quote(host.herdr.isEmpty ? "herdr" : host.herdr)
            r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh),
                                             stdin: Data("\(h) workspace close \(AgentCommands.quote(ws))\n".utf8), timeout: .seconds(12))
        } else {
            guard let herdr = AgentTools.herdr(config) else { return "herdr not found" }
            r = try? await ProcessRunner.run(herdr, ["workspace", "close", ws], timeout: .seconds(5))
        }
        guard let r else { return "Could not run herdr" }
        return r.ok ? nil : Herdr.errorMessage(r.err + r.out)
    }

    /// Sends one line to an agent in herdr (`herdr agent prompt`); it refuses an agent that
    /// waits on a question.
    static func prompt(pane: String, text: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> String? {
        guard Herdr.isSafeID(pane) else { return "Not a herdr pane" }
        let r: ProcessResult?
        if let host {
            let script = Herdr.promptScript(herdr: host.herdr.isEmpty ? "herdr" : host.herdr, pane: pane, text: text)
            r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: Data(script.utf8), timeout: .seconds(15))
        } else {
            guard let herdr = AgentTools.herdr(config) else { return "herdr not found" }
            r = try? await ProcessRunner.run(herdr, ["agent", "prompt", pane, text], timeout: .seconds(10))
        }
        guard let r else { return "Could not run herdr" }
        return r.ok ? nil : Herdr.errorMessage(r.err + r.out)
    }

    /// Answers Claude Code's folder trust question in a hop tmux session with "Yes, I trust
    /// this folder". Only when the user asks; the script checks the question is on screen.
    static func confirmTrust(tmux name: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> String? {
        guard name.hasPrefix("hop-cc-"), AgentCommands.isSafeTmuxName(name) else { return "Not a session hop started" }
        let r: ProcessResult?
        if let host {
            let script = ClaudeTrust.confirmScript(tmux: "tmux", session: name)
            r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: Data(script.utf8),
                                             timeout: .seconds(15))
        } else {
            guard let tmux = AgentTools.tmux(config) else { return "tmux not found" }
            r = try? await ProcessRunner.run("/bin/bash", ["-c", ClaudeTrust.confirmScript(tmux: tmux, session: name)], timeout: .seconds(8))
        }
        guard let r else { return "Could not run tmux" }
        return r.ok ? nil : (r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.status)")
    }

    /// The same for a hop agent in herdr.
    static func confirmTrust(herdrAgent name: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) async -> String? {
        guard name.hasPrefix("hop-cc-"), Herdr.isValidName(name) else { return "Not an agent hop started" }
        let r: ProcessResult?
        if let host {
            let script = ClaudeTrust.confirmScript(herdr: host.herdr.isEmpty ? "herdr" : host.herdr, agent: name)
            r = try? await ProcessRunner.run("/usr/bin/ssh", AgentCommands.sshArguments(host.ssh), stdin: Data(script.utf8),
                                             timeout: .seconds(15))
        } else {
            guard let herdr = AgentTools.herdr(config) else { return "herdr not found" }
            r = try? await ProcessRunner.run("/bin/bash", ["-c", ClaudeTrust.confirmScript(herdr: herdr, agent: name)], timeout: .seconds(8))
        }
        guard let r else { return "Could not run herdr" }
        return r.ok ? nil : (r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.status)")
    }

    /// Opens a terminal attached to an agent in herdr (`herdr agent attach`).
    static func attach(herdrPane pane: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) -> String? {
        guard Herdr.isSafeID(pane) else { return "Not a herdr pane" }
        let binary: String
        if let host {
            binary = host.herdr.isEmpty ? "herdr" : host.herdr
            guard binary.allSatisfy({ !$0.isWhitespace && $0 != "\"" && $0 != "'" }) else { return "Attach to \(pane) over ssh by hand" }
        } else {
            guard let local = AgentTools.herdr(config) else { return "herdr not found" }
            binary = local
        }
        let script = AgentCommands.herdrAttachScript(herdr: binary, pane: pane, sshAlias: host?.ssh)
        return runInTerminal(script, name: "attach-herdr-\(pane.filter { $0.isLetter || $0.isNumber })", config: config)
    }

    /// Opens the configured terminal attached to the tmux session.
    static func attach(tmux name: String, host: HopConfig.Agents.Host?, config: HopConfig.Agents) -> String? {
        if host != nil && !AgentCommands.isSafeTmuxName(name) { return "Attach to “\(name)” over ssh by hand" }
        guard let tmux = host == nil ? AgentTools.tmux(config) : "tmux" else { return "tmux not found" }
        let script = AgentCommands.attachScript(tmux: tmux, session: name, sshAlias: host?.ssh)
        return runInTerminal(script, name: "attach-\(name.filter { $0.isLetter || $0.isNumber || $0 == "-" })", config: config)
    }

    /// Writes a `.command` script and opens it in the terminal app.
    static func runInTerminal(_ script: String, name: String, config: HopConfig.Agents) -> String? {
        let dir = AppPaths.file("Agents")
        let file = dir.appending(path: "\(name).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return "Could not write \(file.lastPathComponent)"
        }
        guard let (id, app) = terminalApp(config.terminal) else { return "No terminal app found" }
        if id == "com.mitchellh.ghostty" {
            // Ghostty runs a command given with -e; a fresh instance opens a window for it.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", app.path, "--args", "-e", file.path]
            do { try p.run() } catch { return "Could not open Ghostty" }
            return nil
        }
        if id == "com.googlecode.iterm2" {
            // iTerm does not run .command files it is handed; its AppleScript does (Automation
            // permission, asked once). Terminal takes over when that is refused.
            let command = "/bin/bash " + AgentCommands.quote(file.path)
            Task {
                let source = "tell application id \"com.googlecode.iterm2\" to create window with default profile command "
                    + AppleScript.quoted(command)
                let ok = (try? await AppleScript.run(source))?.ok ?? false
                if !ok, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    open(file, with: terminal)
                }
            }
            return nil
        }
        open(file, with: app)
        return nil
    }

    private static func open(_ file: URL, with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }

    static func terminalApp(_ choice: HopConfig.Agents.Terminal) -> (String, URL)? {
        let ids: [String] = switch choice {
        case .auto: ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .iterm: ["com.googlecode.iterm2"]
        case .terminal: ["com.apple.Terminal"]
        }
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (id, url) }
        }
        return nil
    }
}

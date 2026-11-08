import Foundation

/// Splits a byte stream into lines: keeps a partial last line until its newline arrives,
/// drops `\r` before `\n` and skips blank lines.
nonisolated struct ChatLineBuffer: Sendable {
    private var pending = Data()
    /// A line longer than this is dropped rather than buffered without end.
    var limit = 32 * 1024 * 1024

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            pending = Data(pending[pending.index(after: nl)...])
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        if pending.count > limit { pending.removeAll() }
        return lines
    }

    /// The last line when the stream ended without a newline.
    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        var line = pending
        if line.last == 0x0D { line = line.dropLast() }
        return line.isEmpty ? [] : [String(decoding: line, as: UTF8.self)]
    }
}

/// Where a chat agent runs: this Mac, or an SSH host (`agents.hosts[].ssh`).
nonisolated struct ChatHost: Equatable, Sendable {
    /// ssh alias or user@host.
    var ssh: String
    /// The agent's command there; empty uses the provider's default (`claude`, `codex`).
    var binary: String = ""
    /// Label shown in the panel (`agents.hosts[].name`).
    var name: String? = nil
}

/// How to start the child: a local process, or ssh feeding a bash script that `exec`s the
/// agent so the rest of stdin is the protocol stream.
nonisolated struct ChatLaunch: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var cwd: String?
    var environment: [String: String]?
    /// Written to stdin before anything else (the remote bootstrap script).
    var preamble: String?

    /// A local agent with the login PATH.
    static func local(binary: String, arguments: [String], cwd: String, path: String) -> ChatLaunch {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        // Claude Code refuses to start nested in another session.
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        return ChatLaunch(executable: binary, arguments: arguments, cwd: cwd.expandingTilde, environment: env)
    }

    /// `ssh alias bash -l -s`, then a script on stdin: bash reads a script from a pipe one byte
    /// at a time, so after `exec` the agent reads the protocol lines that follow. The remote
    /// login shell (fish, often) only ever parses `bash -l -s`.
    static func remote(ssh alias: String, command: [String], cwd: String) -> ChatLaunch {
        ChatLaunch(executable: "/usr/bin/ssh", arguments: AgentCommands.sshArguments(alias), cwd: nil, environment: nil,
                   preamble: remoteScript(command: command, cwd: cwd))
    }

    static func remoteScript(command: [String], cwd: String) -> String {
        let name = command[0].replacingOccurrences(of: "\"", with: "")
        return """
            cd \(AgentCommands.remotePath(cwd)) || { echo "no such folder: \(cwd.replacingOccurrences(of: "\"", with: ""))" >&2; exit 3; }
            command -v \(AgentCommands.quote(command[0])) >/dev/null 2>&1 || { echo "\(name) not found" >&2; exit 5; }
            exec \(command.map(AgentCommands.quote).joined(separator: " "))

            """
    }
}

/// A line-delimited JSON pipe to a child process. Lines and the exit arrive on the main
/// queue, in order.
nonisolated final class ChatTransport: @unchecked Sendable {
    let launch: ChatLaunch
    private let process = Process()
    private let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = ChatLineBuffer()
    private var stderrTail = Data()
    private var inputClosed = false
    private var outDone = false, exited = false, exitReported = false
    private var status: Int32 = 0
    private let onLine: @MainActor (String) -> Void
    private let onExit: @MainActor (Int32, String) -> Void

    /// `onExit` gets the exit status and the tail of stderr.
    init(_ launch: ChatLaunch, onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32, String) -> Void) {
        self.launch = launch
        self.onLine = onLine
        self.onExit = onExit
    }

    var isRunning: Bool { process.isRunning }
    var pid: Int32 { process.processIdentifier }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        if let cwd = launch.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env = launch.environment { process.environment = env }
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            self.lock.lock()
            let lines = data.isEmpty ? self.stdoutBuffer.finish() : self.stdoutBuffer.append(data)
            if data.isEmpty { self.outDone = true; h.readabilityHandler = nil }
            self.lock.unlock()
            if !lines.isEmpty { self.deliver(lines) }
            if data.isEmpty { self.reportExitIfDone() }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            self.lock.lock()
            if data.isEmpty { h.readabilityHandler = nil } else {
                self.stderrTail.append(data)
                if self.stderrTail.count > 16384 { self.stderrTail = Data(self.stderrTail.suffix(8192)) }
            }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            self.exited = true
            self.status = p.terminationStatus
            self.lock.unlock()
            // stdout may still hold lines; give its reader a moment to drain.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                self.lock.lock(); self.outDone = true; self.lock.unlock()
                self.reportExitIfDone()
            }
        }
        // Writing to a child that died must not kill hop.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        if let preamble = launch.preamble { write(preamble) }
    }

    /// Writes one line (a newline is added).
    func send(_ line: String) {
        write(line.hasSuffix("\n") ? line : line + "\n")
    }

    private func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !inputClosed else { return }
        do { try inPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8)) } catch { inputClosed = true }
    }

    /// EOF on the child's stdin: agents in stream mode finish the turn and exit.
    func closeInput() {
        lock.lock(); defer { lock.unlock() }
        guard !inputClosed else { return }
        inputClosed = true
        try? inPipe.fileHandleForWriting.close()
    }

    /// Closes stdin, then SIGTERM, then SIGKILL after `grace` if it is still there.
    func terminate(grace: TimeInterval = 3) {
        closeInput()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
    }

    private func deliver(_ lines: [String]) {
        let onLine = self.onLine
        DispatchQueue.main.async { MainActor.assumeIsolated { for l in lines { onLine(l) } } }
    }

    private func reportExitIfDone() {
        lock.lock()
        guard exited, outDone, !exitReported else { lock.unlock(); return }
        exitReported = true
        let status = self.status
        lock.unlock()
        let err = stderrText
        let onExit = self.onExit
        DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status, err) } }
    }
}

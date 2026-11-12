import Darwin
import Foundation
import os

/// One installed plugin's program, started on demand and spoken to over stdin/stdout
/// (`PluginProtocol`). It is spawned as its own "responsible process", so macOS asks for
/// permissions in its name instead of handing it hop's (Accessibility, Full Disk Access …).
final class PluginProcess {
    enum Failure: Error, CustomStringConvertible {
        case cannotStart(String)
        case exited
        case timedOut(String)
        case plugin(String)

        var description: String {
            switch self {
            case .cannotStart(let why): "could not start: \(why)"
            case .exited: "the plugin quit"
            case .timedOut(let method): "no answer to \(method)"
            case .plugin(let message): message
            }
        }
    }

    let executable: URL
    let directory: URL
    /// Called for `render`, `hud` and other notifications, on the main actor.
    var onNotification: ((String, JSONValue?) -> Void)?
    /// The `initialize` parameters, read each time the program starts.
    var initialize: () -> PluginProtocol.Initialize
    /// Whether to keep the program running when it has been idle (a view is open).
    var keepAlive: () -> Bool = { false }

    private var pid: pid_t = 0
    private var input: FileHandle?
    /// The child's stdout and stderr, kept so their read handlers stay alive.
    private var outputs: [FileHandle] = []
    private var exitSource: DispatchSourceProcess?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var starting: Task<Void, Error>?
    private var idleTimer: Timer?
    private let log = Log.plugin
    private let name: String

    static let idleSeconds: TimeInterval = 60

    init(executable: URL, directory: URL, name: String, initialize: @escaping () -> PluginProtocol.Initialize) {
        self.executable = executable
        self.directory = directory
        self.name = name
        self.initialize = initialize
    }

    var isRunning: Bool { pid != 0 }

    /// Sends a request and waits for its result, starting the program first if needed.
    func request<P: Encodable & Sendable>(_ method: String, _ params: P, timeout: TimeInterval = 15) async throws -> JSONValue {
        try await ensureStarted()
        return try await send(method, params, timeout: timeout)
    }

    func notify<P: Encodable & Sendable>(_ method: String, _ params: P) {
        guard isRunning else { return }
        write(PluginProtocol.Request(id: nil, method: method, params: params))
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard pid != 0 else { return }
        notify("shutdown", [String: String]())
        let victim = pid
        // A second later, if it is still there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { kill(victim, SIGKILL) }
        kill(victim, SIGTERM)
        exited()
    }

    // MARK: Starting

    private func ensureStarted() async throws {
        if isRunning, starting == nil { return }
        if let starting { return try await starting.value }
        let task = Task { [weak self] in
            guard let self else { return }
            try spawn()
            _ = try await send("initialize", initialize(), timeout: 10)
        }
        starting = task
        defer { starting = nil }
        do {
            try await task.value
        } catch {
            stop()
            throw error
        }
    }

    private func spawn() throws {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0, pipe(&errors) == 0 else {
            throw Failure.cannotStart(String(cString: strerror(errno)))
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        for fd in toChild + fromChild + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        Self.disclaim(&attributes)

        let path = executable.path
        let arguments = [path]
        let environment = Self.environment(directory: directory, id: initialize().pluginID)
        var cArgs = arguments.map { strdup($0) } + [nil]
        var cEnv = environment.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, &attributes, &cArgs, &cEnv)
        close(toChild[0])
        close(fromChild[1])
        close(errors[1])
        guard status == 0 else {
            for fd in [toChild[1], fromChild[0], errors[0]] { close(fd) }
            throw Failure.cannotStart(String(cString: strerror(status)))
        }
        pid = child
        input = FileHandle(fileDescriptor: toChild[1], closeOnDealloc: true)
        let stdout = FileHandle(fileDescriptor: fromChild[0], closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: errors[0], closeOnDealloc: true)
        outputs = [stdout, stderr]
        LineReader.start(stdout) { [weak self] line in self?.received(line) }
        let name = self.name
        LineReader.start(stderr) { line in
            let text = "\(name): \(String(decoding: line, as: UTF8.self))"
            Log.plugin.notice("\(text, privacy: .public)")
        }
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            MainActor.assumeIsolated {
                guard let self, self.pid == child else { return }
                let text = "\(self.name) exited (status \(status))"
                Log.plugin.notice("\(text, privacy: .public)")
                self.exited()
            }
        }
        source.resume()
        exitSource = source
        log.info("\(self.name, privacy: .public) started (pid \(child))")
    }

    /// Makes the child its own responsible process for TCC, when this macOS has the call.
    private static func disclaim(_ attributes: inout posix_spawnattr_t?) {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            Log.app.notice("plugins: responsibility_spawnattrs_setdisclaim missing; plugins share hop's permissions")
            return
        }
        _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
    }

    /// A small, predictable environment instead of hop's own.
    static func environment(directory: URL, id: String) -> [String] {
        let env = ProcessInfo.processInfo.environment
        var out = [
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOP_PLUGIN_ID=\(id)",
            "HOP_PLUGIN_DIR=\(directory.path)",
            "HOP_VERSION=\(AppPaths.version)",
        ]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] {
            if let value = env[key] { out.append("\(key)=\(value)") }
        }
        return out
    }

    // MARK: Messages

    private func send<P: Encodable & Sendable>(_ method: String, _ params: P, timeout: TimeInterval) async throws -> JSONValue {
        guard isRunning else { throw Failure.exited }
        let id = nextID
        nextID += 1
        resetIdle()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(PluginProtocol.Request(id: id, method: method, params: params))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let waiting = self?.pending.removeValue(forKey: id) else { return }
                waiting.resume(throwing: Failure.timedOut(method))
            }
        }
    }

    private func write<P: Encodable & Sendable>(_ message: PluginProtocol.Request<P>) {
        let encoder = JSONEncoder()
        // Sorted keys: stable lines, `id` first, easy to read in any language.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard var data = try? encoder.encode(message), let input else { return }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { log.error("\(self.name, privacy: .public): write failed") }
    }

    private func received(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let message = try? JSONDecoder().decode(PluginProtocol.Incoming.self, from: line) else {
            log.error("\(self.name, privacy: .public): not a protocol message: \(String(decoding: line.prefix(200), as: UTF8.self), privacy: .public)")
            return
        }
        if let id = message.id, let waiting = pending.removeValue(forKey: id) {
            if let error = message.error { waiting.resume(throwing: Failure.plugin(error.message)) }
            else { waiting.resume(returning: message.result ?? .null) }
        } else if let method = message.method {
            onNotification?(method, message.params)
        }
    }

    private func exited() {
        pid = 0
        exitSource?.cancel()
        exitSource = nil
        try? input?.close()
        input = nil
        for handle in outputs { handle.readabilityHandler = nil }
        outputs = []
        let waiting = pending
        pending = [:]
        for (_, c) in waiting { c.resume(throwing: Failure.exited) }
    }

    private func resetIdle() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.keepAlive() { self.resetIdle() } else { self.stop() }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }
}

/// Splits what a pipe delivers into lines and hands each to the main actor.
private nonisolated final class LineReader: @unchecked Sendable {
    /// Only touched on the handle's own queue.
    private var buffer = Data()

    static func start(_ handle: FileHandle, line: @escaping @MainActor (Data) -> Void) {
        let reader = LineReader()
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                return
            }
            let lines = reader.append(chunk)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(line) } }
        }
    }

    private func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        // A line this long is not protocol: drop it rather than grow without end.
        if buffer.count > 8 << 20 { buffer.removeAll() }
        return lines
    }
}

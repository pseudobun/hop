import Foundation

nonisolated struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
    var ok: Bool { status == 0 }
}

nonisolated enum ProcessRunnerError: Error { case launch(String) }

/// Runs a subprocess off the main actor, draining stdout and stderr concurrently
/// (large outputs would otherwise fill the 64 KB pipe buffer and deadlock).
nonisolated enum ProcessRunner {
    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    @concurrent
    static func run(_ executable: String, _ arguments: [String] = [], stdin: Data? = nil,
                    environment: [String: String]? = nil, timeout: Duration? = nil) async throws -> ProcessResult {
        let box = Box()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice

        do { try p.run() } catch { throw ProcessRunnerError.launch(error.localizedDescription) }

        if let stdin, let inPipe {
            let w = inPipe.fileHandleForWriting
            try? w.write(contentsOf: stdin)
            try? w.close()
        }

        let watchdog: Task<Void, Never>? = timeout.map { t in
            Task {
                try? await Task.sleep(for: t)
                if !Task.isCancelled && box.process.isRunning { box.process.terminate() }
            }
        }
        defer { watchdog?.cancel() }

        return await withTaskCancellationHandler {
            async let out = readAll(outPipe.fileHandleForReading)
            async let err = readAll(errPipe.fileHandleForReading)
            let (o, e) = await (out, err)
            box.process.waitUntilExit()
            return ProcessResult(status: box.process.terminationStatus, stdout: o, stderr: e)
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    @concurrent
    private static func readAll(_ handle: FileHandle) async -> Data {
        (try? handle.readToEnd()) ?? Data()
    }
}

/// AppleScript via `/usr/bin/osascript`, off the main thread.
nonisolated enum AppleScript {
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func run(_ source: String) async throws -> ProcessResult {
        try await ProcessRunner.run("/usr/bin/osascript", ["-e", source], timeout: .seconds(120))
    }
}

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

/// Runs a subprocess without blocking Swift concurrency threads: pipes are drained
/// on GCD threads (large outputs would otherwise fill the 64 KB pipe buffer) and
/// completion comes from `terminationHandler`, not `waitUntilExit`.
nonisolated enum ProcessRunner {
    private final class State: @unchecked Sendable {
        let process = Process()
        let lock = NSLock()
        var out = Data()
        var err = Data()
    }

    static func run(_ executable: String, _ arguments: [String] = [], stdin: Data? = nil,
                    environment: [String: String]? = nil, timeout: Duration? = nil) async throws -> ProcessResult {
        let state = State()
        let p = state.process
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                let group = DispatchGroup()
                for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        state.lock.withLock { if isOut { state.out = data } else { state.err = data } }
                        group.leave()
                    }
                }
                group.enter()
                p.terminationHandler = { _ in group.leave() }
                do {
                    try p.run()
                } catch {
                    p.terminationHandler = nil
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    cont.resume(throwing: ProcessRunnerError.launch(error.localizedDescription))
                    return
                }
                // The parent's copies of the write ends must close, or the reads never see EOF.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                if let stdin, let inPipe {
                    let w = inPipe.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? w.write(contentsOf: stdin)
                        try? w.close()
                    }
                }
                if let timeout {
                    let c = timeout.components
                    let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                        if state.process.isRunning { state.process.terminate() }
                    }
                }
                group.notify(queue: .global()) {
                    let result = state.lock.withLock {
                        ProcessResult(status: state.process.terminationStatus, stdout: state.out, stderr: state.err)
                    }
                    cont.resume(returning: result)
                }
            }
        } onCancel: {
            if state.process.isRunning { state.process.terminate() }
        }
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

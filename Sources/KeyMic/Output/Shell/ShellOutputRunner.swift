import Foundation
import os.log

private let shellOutputLogger = Logger(subsystem: "io.keymic.app", category: "ShellOutputRunner")

struct ShellOutputResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellOutputRunnerError: Error, Equatable {
    case launchFailed(String)
    case timeout
}

/// Pure-ish wrapper around `Process` for `.runShell` injection strategy. Captures
/// stdout + stderr without deadlock by draining both pipes on background queues
/// (the 64 KB pipe buffer otherwise blocks `Process` once full).
///
/// Disambiguated from `Tools/Shell/ShellRunner` (which serves persona context
/// `.shellOutput`) by suffix `OutputRunner`. This one returns captured stdout to
/// the caller for injection; the other one logs stdout but only returns exit code.
///
/// Env passthrough strips `KEYMIC_*` keys defensively. cwd = $HOME.
enum ShellOutputRunner {
    static func run(_ command: String, timeout: TimeInterval = 30) async throws -> ShellOutputResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShellOutputResult, Error>) in
            let process = Process()
            process.launchPath = "/bin/zsh"
            process.arguments = ["-c", command]
            process.currentDirectoryPath = NSHomeDirectory()

            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("KEYMIC_") { env.removeValue(forKey: key) }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

            let stdoutBox = ShellOutputDataBox()
            let stderrBox = ShellOutputDataBox()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; return }
                stdoutBox.append(chunk)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; return }
                stderrBox.append(chunk)
            }

            let timeoutSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let resumed = ShellOutputResumedFlag()
            timeoutSource.schedule(deadline: .now() + timeout)
            timeoutSource.setEventHandler {
                if process.isRunning { process.terminate() }
                if resumed.set() {
                    cont.resume(throwing: ShellOutputRunnerError.timeout)
                }
                timeoutSource.cancel()
            }
            timeoutSource.resume()

            process.terminationHandler = { proc in
                timeoutSource.cancel()
                stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(data: stdoutBox.snapshot(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
                let result = ShellOutputResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus)
                if resumed.set() {
                    cont.resume(returning: result)
                }
            }

            do {
                try process.run()
                shellOutputLogger.debug("launched pid=\(process.processIdentifier, privacy: .public) timeout=\(timeout, privacy: .public)s")
            } catch {
                timeoutSource.cancel()
                if resumed.set() {
                    cont.resume(throwing: ShellOutputRunnerError.launchFailed(error.localizedDescription))
                }
            }
        }
    }
}

/// Thread-safe data accumulator for pipe drains.
private final class ShellOutputDataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// One-shot flag: ensures we only `cont.resume(...)` once across timeout-vs-termination race.
private final class ShellOutputResumedFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    /// Returns true iff this caller is the first to set the flag.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

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
/// Completion model: each pipe is read exclusively via its `readabilityHandler`
/// until EOF (`availableData.isEmpty`); EOF — not process termination — is the
/// read-complete signal. Both EOFs and termination rendezvous through a
/// `DispatchGroup`. Never mixes `readabilityHandler` with blocking
/// `readDataToEndOfFile()` on the same FileHandle (documented as unsupported, and
/// the blocking read hangs forever if a backgrounded child inherits the pipe's
/// write end). A post-exit grace deadline force-finishes the reads so a daemonized
/// child holding the write end can't leak the continuation.
///
/// Env passthrough strips `KEYMIC_*` keys defensively. cwd = $HOME.
enum ShellOutputRunner {
    /// How long after process exit we keep waiting for pipe EOF before returning
    /// with whatever output was collected (covers `cmd &`-style children that
    /// inherit the write ends and never close them).
    private static let postExitDrainGrace: TimeInterval = 2
    /// SIGTERM → SIGKILL escalation grace on timeout.
    private static let sigkillGrace: TimeInterval = 5

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

            let queue = DispatchQueue.global(qos: .utility)
            let group = DispatchGroup()
            let stdoutBox = ShellOutputDataBox()
            let stderrBox = ShellOutputDataBox()

            // Drain a pipe via readabilityHandler until EOF. The one-shot flag guards
            // group.leave() so the post-exit grace path can't double-leave when racing
            // a late EOF.
            func wire(_ handle: FileHandle, into box: ShellOutputDataBox) -> ShellOutputOneShotFlag {
                let done = ShellOutputOneShotFlag()
                group.enter()
                handle.readabilityHandler = { h in
                    let chunk = h.availableData
                    if chunk.isEmpty {
                        if done.set() {
                            h.readabilityHandler = nil
                            group.leave()
                        }
                        return
                    }
                    box.append(chunk)
                }
                return done
            }
            let stdoutDone = wire(stdoutPipe.fileHandleForReading, into: stdoutBox)
            let stderrDone = wire(stderrPipe.fileHandleForReading, into: stderrBox)

            let resumed = ShellOutputOneShotFlag()
            let exitCode = ShellOutputExitCodeBox()

            let timeoutSource = DispatchSource.makeTimerSource(queue: queue)
            timeoutSource.schedule(deadline: .now() + timeout)
            timeoutSource.setEventHandler {
                if process.isRunning {
                    // Kill the whole tree, not just the top-level zsh: SIGTERM each
                    // pid, then escalate to SIGKILL after a grace period. Plain
                    // `process.terminate()` orphans children and is ignorable.
                    let tree = ShellProcessTree.collect(process.processIdentifier)
                    for pid in tree { kill(pid, SIGTERM) }
                    queue.asyncAfter(deadline: .now() + sigkillGrace) {
                        for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                    }
                }
                if resumed.set() {
                    cont.resume(throwing: ShellOutputRunnerError.timeout)
                }
            }
            timeoutSource.resume()

            // Force-finish both reads (used by the post-exit grace deadline).
            func finishReads() {
                if stdoutDone.set() {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    group.leave()
                }
                if stderrDone.set() {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    group.leave()
                }
            }

            group.enter() // termination
            process.terminationHandler = { proc in
                exitCode.value = proc.terminationStatus
                group.leave()
                // The process exited, but a backgrounded child may still hold the
                // pipe write ends (no EOF ever arrives). Give the drain a short
                // grace, then force-finish with whatever was collected.
                queue.asyncAfter(deadline: .now() + postExitDrainGrace) {
                    finishReads()
                }
            }

            do {
                try process.run()
                shellOutputLogger.debug("launched pid=\(process.processIdentifier, privacy: .public) timeout=\(timeout, privacy: .public)s")
            } catch {
                timeoutSource.cancel()
                finishReads()
                if resumed.set() {
                    cont.resume(throwing: ShellOutputRunnerError.launchFailed(error.localizedDescription))
                }
                return
            }

            // Fires once both pipes hit EOF (or were force-finished) AND the process
            // terminated. Registered after run() so a launch failure can't fire it
            // with an unset exit code.
            group.notify(queue: queue) {
                timeoutSource.cancel()
                let stdout = String(data: stdoutBox.snapshot(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
                let result = ShellOutputResult(stdout: stdout, stderr: stderr, exitCode: exitCode.value)
                if resumed.set() {
                    cont.resume(returning: result)
                }
            }
        }
    }
}

/// Best-effort process-tree enumeration via `ps` (root first, then descendants).
/// Drains the ps pipe with `readDataToEndOfFile` BEFORE `waitUntilExit` — the read
/// blocks until ps closes stdout at exit, so it drains concurrently and cannot
/// deadlock against a full 64 KB pipe buffer. Known limitation (accepted): a pid
/// can be reused between the ps snapshot and the kill.
enum ShellProcessTree {
    static func collect(_ rootPid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid,ppid"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [rootPid] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        var children: [Int32: [Int32]] = [:]
        for line in output.components(separatedBy: "\n") {
            let cols = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard cols.count >= 2, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            children[ppid, default: []].append(pid)
        }

        var pids: [Int32] = []
        func walk(_ pid: Int32) {
            pids.append(pid)
            for child in children[pid] ?? [] { walk(child) }
        }
        walk(rootPid)
        return pids
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

/// Thread-safe exit-code cell written by the termination handler.
private final class ShellOutputExitCodeBox: @unchecked Sendable {
    private var code: Int32 = -1
    private let lock = NSLock()
    var value: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return code }
        set { lock.lock(); defer { lock.unlock() }; code = newValue }
    }
}

/// One-shot flag: first caller of `set()` wins. Guards `cont.resume(...)` across
/// the timeout-vs-completion race and `group.leave()` across EOF-vs-grace races.
private final class ShellOutputOneShotFlag: @unchecked Sendable {
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

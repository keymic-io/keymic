import Foundation

private final class ShellRunnerTests {
    static func main() throws {
        try testSimpleExitZero()
        try testNonZeroExit()
        try testSnapshotAliasResolved()
        try testSnapshotFunctionResolved()
        try testFallbackWhenNoSnapshot()
        try testCommandContainingSingleQuote()
        try testStderrCapturedToLog()
        try testTimeoutSigterm()
        try testRunAndCaptureReturnsOutput()
        try testRunExecSyncCapturesOutput()
        try testRunExecSyncArgvNotShellInterpreted()
        try testRunExecSyncNonZeroAndStderr()
        try testRunExecSyncTimeout()
        try testLaunchDetachedSpawns()
        print("ShellRunnerTests passed")
    }

    final class CapturedLogger: ShellLogger {
        var entries: [ShellLogEntry] = []
        private let lock = NSLock()
        override func log(_ entry: ShellLogEntry) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }
    }

    static func makeRunner(snapshot: URL?, captured: CapturedLogger) -> ShellRunner {
        ShellRunner(
            snapshotProvider: { snapshot },
            logger: captured,
            shellPath: "/bin/zsh",
            commandTimeout: 30,
            sigkillGrace: 5
        )
    }

    static func writeFixtureSnapshot() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-runner-snap-\(UUID().uuidString).sh")
        let content = """
        alias hello='echo hi-from-alias'
        nvm() { echo nvm-from-function; }
        """
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    static func testSimpleExitZero() throws {
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: nil, captured: logger)
        let code = runner.run("true")
        guard code == 0 else { fatalError("testSimpleExitZero: expected 0, got \(code)") }
    }

    static func testNonZeroExit() throws {
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: nil, captured: logger)
        let code = runner.run("false")
        guard code == 1 else { fatalError("testNonZeroExit: expected 1, got \(code)") }
    }

    static func testSnapshotAliasResolved() throws {
        let snap = try writeFixtureSnapshot()
        defer { try? FileManager.default.removeItem(at: snap) }
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: snap, captured: logger)
        let code = runner.run("hello")
        guard code == 0 else {
            fatalError("testSnapshotAliasResolved: expected 0, got \(code); stderr=\(logger.entries.last?.stderr ?? "")")
        }
        guard logger.entries.last?.stdout.contains("hi-from-alias") == true else {
            fatalError("testSnapshotAliasResolved: stdout missing, got '\(logger.entries.last?.stdout ?? "")'")
        }
    }

    static func testSnapshotFunctionResolved() throws {
        let snap = try writeFixtureSnapshot()
        defer { try? FileManager.default.removeItem(at: snap) }
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: snap, captured: logger)
        let code = runner.run("nvm")
        guard code == 0 else {
            fatalError("testSnapshotFunctionResolved: expected 0, got \(code); stderr=\(logger.entries.last?.stderr ?? "")")
        }
        guard logger.entries.last?.stdout.contains("nvm-from-function") == true else {
            fatalError("testSnapshotFunctionResolved: stdout missing, got '\(logger.entries.last?.stdout ?? "")'")
        }
    }

    static func testFallbackWhenNoSnapshot() throws {
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: nil, captured: logger)
        let code = runner.run("echo ok")
        guard code == 0 else { fatalError("testFallbackWhenNoSnapshot: expected 0, got \(code)") }
        guard logger.entries.last?.fallback == true else {
            fatalError("testFallbackWhenNoSnapshot: log entry should mark fallback=true")
        }
    }

    static func testCommandContainingSingleQuote() throws {
        // Verifies posixQuote correctly escapes ' → '\'' so the command
        // reaches eval intact. eval 'echo "it'\''s here"' → echo "it's here"
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: nil, captured: logger)
        let code = runner.run(#"echo "it's here""#)
        guard code == 0 else { fatalError("testCommandContainingSingleQuote: exit \(code)") }
        let out = logger.entries.last?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard out == "it's here" else {
            fatalError("testCommandContainingSingleQuote: expected \"it's here\", got '\(out)'")
        }
    }

    static func testStderrCapturedToLog() throws {
        let logger = CapturedLogger()
        let runner = makeRunner(snapshot: nil, captured: logger)
        _ = runner.run("ls /nonexistent-keymic-path")
        guard let entry = logger.entries.last else { fatalError("no log entry") }
        guard entry.stderr.contains("nonexistent") || entry.stderr.lowercased().contains("no such") else {
            fatalError("testStderrCapturedToLog: stderr not captured, got '\(entry.stderr)'")
        }
    }

    static func testTimeoutSigterm() throws {
        let logger = CapturedLogger()
        let runner = ShellRunner(
            snapshotProvider: { nil },
            logger: logger,
            shellPath: "/bin/zsh",
            commandTimeout: 2,
            sigkillGrace: 1
        )
        let t0 = Date()
        let code = runner.run("sleep 30")
        let elapsed = Date().timeIntervalSince(t0)
        guard elapsed < 5 else { fatalError("testTimeoutSigterm: elapsed=\(elapsed)s, expected <5") }
        // macOS Process.terminationStatus returns signal number (positive) when killed by signal
        let validExits: [Int32] = [15, 9]  // SIGTERM=15, SIGKILL=9
        guard validExits.contains(code) else {
            fatalError("testTimeoutSigterm: expected 15 or 9, got \(code)")
        }
    }

    static func testRunAndCaptureReturnsOutput() throws {
        let captured = CapturedLogger()
        let runner = makeRunner(snapshot: nil, captured: captured)

        let semaphore = DispatchSemaphore(value: 0)
        var result: (exitCode: Int32, stdout: String, stderr: String)!
        Task {
            result = await runner.runAndCapture("echo hello && echo oops 1>&2")
            semaphore.signal()
        }
        semaphore.wait()

        guard result.exitCode == 0 else {
            fatalError("expected exit 0, got \(result.exitCode)")
        }
        guard result.stdout.contains("hello") else {
            fatalError("stdout missing 'hello': '\(result.stdout)'")
        }
        guard result.stderr.contains("oops") else {
            fatalError("stderr missing 'oops': '\(result.stderr)'")
        }

        // Log-entry assertion: runAndCapture must produce the same log row
        // as run(_:). Cheap insurance against the runAndLog refactor.
        guard let entry = captured.entries.last, entry.stdout.contains("hello") else {
            fatalError("expected ShellLogEntry from runAndCapture to capture stdout")
        }
    }

    static func testRunExecSyncCapturesOutput() throws {
        let runner = makeRunner(snapshot: nil, captured: CapturedLogger())
        let r = runner.runExecSync(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        guard r.exitCode == 0 else { fatalError("testRunExecSyncCapturesOutput: exit \(r.exitCode)") }
        guard r.stdout.contains("hello") else {
            fatalError("testRunExecSyncCapturesOutput: stdout '\(r.stdout)'")
        }
    }

    static func testRunExecSyncArgvNotShellInterpreted() throws {
        // Exec mode does NOT go through a shell: $HOME and ; reach the binary
        // verbatim instead of being expanded / treated as a separator.
        let runner = makeRunner(snapshot: nil, captured: CapturedLogger())
        let r = runner.runExecSync(URL(fileURLWithPath: "/bin/echo"), arguments: ["$HOME ; rm"])
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out == "$HOME ; rm" else {
            fatalError("testRunExecSyncArgvNotShellInterpreted: expected literal, got '\(out)'")
        }
    }

    static func testRunExecSyncNonZeroAndStderr() throws {
        let runner = makeRunner(snapshot: nil, captured: CapturedLogger())
        let r = runner.runExecSync(URL(fileURLWithPath: "/bin/ls"),
                                   arguments: ["/nonexistent-keymic-exec-path"])
        guard r.exitCode != 0 else { fatalError("testRunExecSyncNonZeroAndStderr: expected non-zero") }
        guard !r.stderr.isEmpty else { fatalError("testRunExecSyncNonZeroAndStderr: stderr empty") }
    }

    static func testRunExecSyncTimeout() throws {
        let runner = makeRunner(snapshot: nil, captured: CapturedLogger())
        let t0 = Date()
        let r = runner.runExecSync(URL(fileURLWithPath: "/bin/sleep"),
                                   arguments: ["30"], timeout: 2)
        let elapsed = Date().timeIntervalSince(t0)
        guard elapsed < 5 else { fatalError("testRunExecSyncTimeout: elapsed=\(elapsed)s") }
        let validExits: [Int32] = [15, 9]  // SIGTERM / SIGKILL
        guard validExits.contains(r.exitCode) else {
            fatalError("testRunExecSyncTimeout: expected 15 or 9, got \(r.exitCode)")
        }
    }

    static func testLaunchDetachedSpawns() throws {
        let runner = makeRunner(snapshot: nil, captured: CapturedLogger())
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-detached-\(UUID().uuidString).marker")
        // launchDetached returns immediately; verify it actually spawned the
        // child by polling for its side effect.
        runner.launchDetached(URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path])
        var appeared = false
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: marker.path) { appeared = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? FileManager.default.removeItem(at: marker)
        guard appeared else { fatalError("testLaunchDetachedSpawns: marker never created") }
    }
}

@main
private enum RunnerTestRunner {
    static func main() throws {
        try ShellRunnerTests.main()
    }
}

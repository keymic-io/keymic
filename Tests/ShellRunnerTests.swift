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
}

@main
private enum RunnerTestRunner {
    static func main() throws {
        try ShellRunnerTests.main()
    }
}

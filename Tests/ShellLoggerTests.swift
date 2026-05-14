import Foundation

@main
struct ShellLoggerTests {
    static func main() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-shell-logger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try testWriteAppendsLine(tmp: tmp)
        try testRotationAt5MB(tmp: tmp)
        try testMultipleRotationsKeepOnlyOne(tmp: tmp)
        try testConcurrentWritesSerialized(tmp: tmp)
        try testIOErrorSwallowed(tmp: tmp)

        print("ShellLoggerTests passed")
    }

    static func testWriteAppendsLine(tmp: URL) throws {
        let logURL = tmp.appendingPathComponent("test-write.log")
        let logger = ShellLogger(logURL: logURL, maxBytes: 1024 * 1024)
        logger.log(ShellLogEntry(
            timestamp: Date(timeIntervalSince1970: 1700000000),
            command: "true",
            exitCode: 0,
            stdout: "",
            stderr: "",
            durationMs: 12,
            fallback: false
        ))
        logger.flushForTesting()
        let content = try String(contentsOf: logURL, encoding: .utf8)
        guard content.contains("[Shell]"),
              content.contains("exit=0"),
              content.contains("cmd: true") else {
            fatalError("testWriteAppendsLine: missing fields in \(content)")
        }
    }

    static func testRotationAt5MB(tmp: URL) throws {
        let logURL = tmp.appendingPathComponent("test-rot.log")
        let garbage = String(repeating: "x", count: 6 * 1024 * 1024)
        try garbage.write(to: logURL, atomically: true, encoding: .utf8)
        let logger = ShellLogger(logURL: logURL, maxBytes: 5 * 1024 * 1024)
        logger.log(ShellLogEntry(timestamp: Date(), command: "echo hi", exitCode: 0,
                                  stdout: "", stderr: "", durationMs: 1, fallback: false))
        logger.flushForTesting()
        let backupURL = logURL.appendingPathExtension("1")
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            fatalError("testRotationAt5MB: backup not created")
        }
        let newSize = (try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? -1
        guard newSize > 0 && newSize < 1024 else {
            fatalError("testRotationAt5MB: new log size unexpected \(newSize)")
        }
    }

    static func testMultipleRotationsKeepOnlyOne(tmp: URL) throws {
        let logURL = tmp.appendingPathComponent("test-multi.log")
        let logger = ShellLogger(logURL: logURL, maxBytes: 100)
        for i in 0..<5 {
            logger.log(ShellLogEntry(timestamp: Date(), command: "cmd\(i)", exitCode: 0,
                                      stdout: String(repeating: "y", count: 200),
                                      stderr: "", durationMs: 1, fallback: false))
            logger.flushForTesting()
        }
        let dir = logURL.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("test-multi.log") }
        guard entries.count <= 2 else {
            fatalError("testMultipleRotationsKeepOnlyOne: too many files \(entries)")
        }
    }

    static func testConcurrentWritesSerialized(tmp: URL) throws {
        let logURL = tmp.appendingPathComponent("test-concurrent.log")
        let logger = ShellLogger(logURL: logURL, maxBytes: 100 * 1024 * 1024)
        let group = DispatchGroup()
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                logger.log(ShellLogEntry(timestamp: Date(), command: "c\(i)", exitCode: 0,
                                          stdout: "", stderr: "", durationMs: 0, fallback: false))
                group.leave()
            }
        }
        group.wait()
        logger.flushForTesting()
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n").count
        guard lines == 100 else {
            fatalError("testConcurrentWritesSerialized: expected 100 lines, got \(lines)")
        }
    }

    static func testIOErrorSwallowed(tmp: URL) throws {
        let logURL = URL(fileURLWithPath: "/dev/null/cannot-write.log")
        let logger = ShellLogger(logURL: logURL, maxBytes: 1024)
        logger.log(ShellLogEntry(timestamp: Date(), command: "x", exitCode: 0,
                                  stdout: "", stderr: "", durationMs: 0, fallback: false))
        logger.flushForTesting()
        // no crash = pass
    }
}

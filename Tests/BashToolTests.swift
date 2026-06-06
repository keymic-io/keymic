import Foundation

private final class BashToolTests {
    static func main() throws {
        try testEchoCommand()
        try testNonZeroExitReportedInOutput()
        try testSchemaHasCommandRequired()
        try testTruncationWithCJK()
        try testNoOutputSentinel()
        try testWorkingDirectoryHonored()
        print("BashToolTests passed")
    }

    /// Build a BashTool wired to an in-memory logger and no snapshot.
    static func makeTool() -> BashTool {
        let runner = ShellRunner(
            snapshotProvider: { nil },
            logger: ShellLogger.shared,
            shellPath: "/bin/zsh",
            commandTimeout: 30,
            sigkillGrace: 5
        )
        return BashTool(runner: runner)
    }

    static func testEchoCommand() throws {
        let tool = makeTool()
        let input = #"{"command":"echo hi"}"#.data(using: .utf8)!
        let context = ToolContext()
        let output = try runAsync {
            try await tool.call(argumentsJSON: input, context: context)
        }
        guard output.contains("hi") else {
            fatalError("expected output to contain 'hi', got: \(output)")
        }
    }

    static func testNonZeroExitReportedInOutput() throws {
        let tool = makeTool()
        let input = #"{"command":"exit 7"}"#.data(using: .utf8)!
        let context = ToolContext()
        let output = try runAsync {
            try await tool.call(argumentsJSON: input, context: context)
        }
        guard output.contains("exit code: 7") else {
            fatalError("expected output to mention 'exit code: 7', got: \(output)")
        }
    }

    static func testSchemaHasCommandRequired() throws {
        let tool = makeTool()
        let schema = tool.parametersJSONSchema
        guard let required = schema["required"] as? [String], required.contains("command") else {
            fatalError("schema must require 'command'")
        }
        guard let props = schema["properties"] as? [String: Any],
              let command = props["command"] as? [String: Any],
              (command["type"] as? String) == "string"
        else {
            fatalError("schema.properties.command.type must be 'string'")
        }
    }

    static func testTruncationWithCJK() throws {
        let tool = makeTool()
        // Output 200 copies of a 3-byte UTF-8 character (CJK '中') = 600 bytes.
        // With maxOutputBytes=120, half is 60 bytes — 20 chars worth.
        // Without UTF-8-safe truncation, the boundary would land mid-sequence
        // and either half could decode to "" (silent data loss).
        let input = #"{"command":"printf '中%.0s' {1..200}"}"#.data(using: .utf8)!
        let context = ToolContext(maxOutputBytes: 120)
        let output = try runAsync {
            try await tool.call(argumentsJSON: input, context: context)
        }
        guard output.contains("... [output truncated] ...") else {
            fatalError("expected truncation marker, got: \(output.prefix(200))")
        }
        // Both halves should contain '中' characters — proves UTF-8 safety.
        let parts = output.components(separatedBy: "... [output truncated] ...")
        guard parts.count == 2 else {
            fatalError("expected 2 parts split by marker, got \(parts.count)")
        }
        guard parts[0].contains("中") else {
            fatalError("prefix half lost CJK content (UTF-8 boundary bug?), got: '\(parts[0])'")
        }
        guard parts[1].contains("中") else {
            fatalError("suffix half lost CJK content (UTF-8 boundary bug?), got: '\(parts[1])'")
        }
    }

    static func testNoOutputSentinel() throws {
        let tool = makeTool()
        // `true` exits 0 with no stdout or stderr.
        let input = #"{"command":"true"}"#.data(using: .utf8)!
        let context = ToolContext()
        let output = try runAsync {
            try await tool.call(argumentsJSON: input, context: context)
        }
        guard output == "(no output)" else {
            fatalError("expected literal '(no output)', got: '\(output)'")
        }
    }

    static func testWorkingDirectoryHonored() throws {
        let tool = makeTool()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-bashtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // macOS resolves /var to /private/var; use the resolved path for compare.
        let expected = tmp.resolvingSymlinksInPath().path

        let input = #"{"command":"pwd"}"#.data(using: .utf8)!
        let context = ToolContext(workingDirectory: tmp.path)
        let output = try runAsync {
            try await tool.call(argumentsJSON: input, context: context)
        }
        guard output.contains(expected) else {
            fatalError("expected pwd to be \(expected), got: \(output)")
        }
    }

    static func runAsync<T>(_ work: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}

@main
private enum BashToolTestRunner {
    static func main() throws {
        try BashToolTests.main()
    }
}

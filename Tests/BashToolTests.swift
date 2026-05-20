import Foundation

private final class BashToolTests {
    static func main() throws {
        try testEchoCommand()
        try testNonZeroExitReportedInOutput()
        try testSchemaHasCommandRequired()
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

import Foundation

private final class MultiEditToolTests {
    static func main() throws {
        try testSequentialEdits()
        try testAllOrNothingOnError()
        try testInvalidEditsJSON()
        try testSandboxEscapeRejected()
        print("MultiEditToolTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-multieditool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func writeFixture(_ dir: String, content: String) -> String {
        let p = dir + "/x.txt"
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    static func testSequentialEdits() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "alpha beta gamma")
        let tool = MultiEditTool()
        let input = #"""
        {"file_path":"x.txt","edits":[{"old":"alpha","new":"AAA"},{"old":"gamma","new":"GGG"}]}
        """#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("Success") && out.contains("2 edit") else {
            fatalError("expected success with 2 edits, got: \(out)")
        }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "AAA beta GGG" else { fatalError("content: \(content)") }
    }

    static func testAllOrNothingOnError() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "alpha beta")
        let tool = MultiEditTool()
        // Second edit has empty old → invalid, must abort + leave file unchanged.
        let input = #"""
        {"file_path":"x.txt","edits":[{"old":"alpha","new":"AAA"},{"old":"","new":"GGG"}]}
        """#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
            fatalError("expected validation error on empty old_string")
        } catch FileSystemError.operationFailed {
            // expected
        } catch {
            fatalError("expected operationFailed, got: \(error)")
        }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "alpha beta" else { fatalError("file should be unchanged, got: \(content)") }
    }

    static func testInvalidEditsJSON() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "hi")
        let tool = MultiEditTool()
        // edits must be an array; passing a string should fail to decode.
        let input = #"""
        {"file_path":"x.txt","edits":"not-an-array"}
        """#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
            fatalError("expected decode error")
        } catch {
            // Either DecodingError or FileSystemError — both acceptable.
        }
    }

    static func testSandboxEscapeRejected() throws {
        let dir = tmpDir()
        let tool = MultiEditTool()
        let input = #"""
        {"file_path":"../escape.txt","edits":[{"old":"a","new":"b"}]}
        """#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
            fatalError("expected pathNotSafe error")
        } catch FileSystemError.pathNotSafe {
            // expected
        } catch {
            fatalError("expected pathNotSafe, got: \(error)")
        }
    }

    static func runAsyncThrowing<T>(_ work: @escaping () async throws -> T) throws -> T {
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
private enum MultiEditToolTestRunner {
    static func main() throws {
        try MultiEditToolTests.main()
    }
}

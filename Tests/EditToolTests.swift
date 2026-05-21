import Foundation

private final class EditToolTests {
    static func main() throws {
        try testSingleReplace()
        try testReplaceAll()
        try testMissingOldStringNoChange()
        try testNonUniqueWithoutReplaceAllFails()
        try testSandboxEscapeRejected()
        print("EditToolTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-edittool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func writeFixture(_ dir: String, content: String) -> String {
        let p = dir + "/x.txt"
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    static func testSingleReplace() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "hello world")
        let tool = EditTool()
        let input = #"{"file_path":"x.txt","old_string":"world","new_string":"swift"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("Success") else { fatalError("expected success, got: \(out)") }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "hello swift" else { fatalError("expected 'hello swift', got: '\(content)'") }
    }

    static func testReplaceAll() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "foo bar foo bar foo")
        let tool = EditTool()
        let input = #"{"file_path":"x.txt","old_string":"foo","new_string":"baz","replace_all":true}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("3 occurrence") else { fatalError("expected 3 replacements, got: \(out)") }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "baz bar baz bar baz" else { fatalError("content: \(content)") }
    }

    static func testMissingOldStringNoChange() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "hello")
        let tool = EditTool()
        let input = #"{"file_path":"x.txt","old_string":"absent","new_string":"present"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("Failed") || out.contains("not found") else {
            fatalError("expected failure for missing old_string, got: \(out)")
        }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "hello" else { fatalError("file should be unchanged, got: \(content)") }
    }

    static func testNonUniqueWithoutReplaceAllFails() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "foo foo")
        let tool = EditTool()
        let input = #"{"file_path":"x.txt","old_string":"foo","new_string":"bar"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("Failed") && out.contains("2 occurrences") else {
            fatalError("expected non-unique failure, got: \(out)")
        }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "foo foo" else { fatalError("file should be unchanged, got: \(content)") }
    }

    static func testSandboxEscapeRejected() throws {
        let dir = tmpDir()
        let tool = EditTool()
        let input = #"{"file_path":"../escape.txt","old_string":"a","new_string":"b"}"#.data(using: .utf8)!
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
private enum EditToolTestRunner {
    static func main() throws {
        try EditToolTests.main()
    }
}

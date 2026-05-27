import Foundation

private final class WriteToolTests {
    static func main() throws {
        try testCreateNewFile()
        try testOverwriteExisting()
        try testCreatesParentDir()
        try testSandboxEscapeRejected()
        try testSchemaShape()
        print("WriteToolTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-writetool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func testCreateNewFile() throws {
        let dir = tmpDir()
        let tool = WriteTool()
        let input = #"{"file_path":"new.txt","content":"hello"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("created successfully") else {
            fatalError("expected create confirmation, got: \(out)")
        }
        let content = try String(contentsOfFile: dir + "/new.txt", encoding: .utf8)
        guard content == "hello" else { fatalError("file content mismatch: \(content)") }
    }

    static func testOverwriteExisting() throws {
        let dir = tmpDir()
        try "old".write(toFile: dir + "/x.txt", atomically: true, encoding: .utf8)
        let tool = WriteTool()
        let input = #"{"file_path":"x.txt","content":"new"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("overwritten successfully") else {
            fatalError("expected overwrite confirmation, got: \(out)")
        }
        let content = try String(contentsOfFile: dir + "/x.txt", encoding: .utf8)
        guard content == "new" else { fatalError("file content mismatch: \(content)") }
    }

    static func testCreatesParentDir() throws {
        let dir = tmpDir()
        let tool = WriteTool()
        let input = #"{"file_path":"deep/nested/file.txt","content":"x"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard FileManager.default.fileExists(atPath: dir + "/deep/nested/file.txt") else {
            fatalError("parent dir not created")
        }
    }

    static func testSandboxEscapeRejected() throws {
        let dir = tmpDir()
        let tool = WriteTool()
        let input = #"{"file_path":"../escape.txt","content":"x"}"#.data(using: .utf8)!
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

    static func testSchemaShape() throws {
        let tool = WriteTool()
        let schema = tool.parametersJSONSchema
        guard let required = schema["required"] as? [String],
              required.contains("file_path") && required.contains("content") else {
            fatalError("schema must require file_path and content")
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
private enum WriteToolTestRunner {
    static func main() throws {
        try WriteToolTests.main()
    }
}

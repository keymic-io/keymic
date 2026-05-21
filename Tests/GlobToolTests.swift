import Foundation

private final class GlobToolTests {
    static func main() throws {
        try testFlatPatternFindsMatches()
        try testRecursivePatternFindsNestedMatches()
        try testQuestionMarkSingleChar()
        try testFileTypeFilterDirectory()
        try testFileTypeFilterAny()
        try testCaseInsensitiveMatching()
        try testEmptyResultIsSuccess()
        try testMissingBasePathThrows()
        try testSandboxEscapeRejected()
        try testSubpathArgumentRespected()
        try testSchemaShape()
        print("GlobToolTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-globtool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @discardableResult
    static func makeDir(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    static func writeFile(_ path: String, _ content: String = "") throws -> String {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static func toolOutput(
        pattern: String,
        path: String? = nil,
        fileType: String? = nil,
        caseSensitive: Bool? = nil,
        workingDirectory: String
    ) throws -> String {
        var payload: [String: Any] = ["pattern": pattern]
        if let path { payload["path"] = path }
        if let fileType { payload["file_type"] = fileType }
        if let caseSensitive { payload["case_sensitive"] = caseSensitive }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let tool = GlobTool()
        let context = ToolContext(workingDirectory: workingDirectory)
        return try runAsyncThrowing { try await tool.call(argumentsJSON: data, context: context) }
    }

    static func testFlatPatternFindsMatches() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift")
        try writeFile(dir + "/b.swift")
        try writeFile(dir + "/c.txt")

        let out = try toolOutput(pattern: "*.swift", workingDirectory: dir)
        guard out.contains("Found 2 match") else {
            fatalError("expected two matches, got: \(out)")
        }
        guard out.contains("a.swift") && out.contains("b.swift") else {
            fatalError("expected swift files in output, got: \(out)")
        }
        guard !out.contains("c.txt") else {
            fatalError("unexpected txt file in output: \(out)")
        }
    }

    static func testRecursivePatternFindsNestedMatches() throws {
        let dir = tmpDir()
        try writeFile(dir + "/top.swift")
        try makeDir(dir + "/src/sub")
        try writeFile(dir + "/src/inner.swift")
        try writeFile(dir + "/src/sub/deep.swift")
        try writeFile(dir + "/src/inner.txt")

        let out = try toolOutput(pattern: "**/*.swift", workingDirectory: dir)
        guard out.contains("top.swift") else { fatalError("expected top-level swift file: \(out)") }
        guard out.contains("src/inner.swift") else { fatalError("expected nested swift file: \(out)") }
        guard out.contains("src/sub/deep.swift") else { fatalError("expected deep swift file: \(out)") }
        guard !out.contains("src/inner.txt") else { fatalError("unexpected txt file: \(out)") }
    }

    static func testQuestionMarkSingleChar() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.txt")
        try writeFile(dir + "/b.txt")
        try writeFile(dir + "/ab.txt")

        let out = try toolOutput(pattern: "?.txt", workingDirectory: dir)
        guard out.contains("a.txt") && out.contains("b.txt") else {
            fatalError("expected single-character matches, got: \(out)")
        }
        guard !out.contains("ab.txt") else {
            fatalError("unexpected multi-character match, got: \(out)")
        }
    }

    static func testFileTypeFilterDirectory() throws {
        let dir = tmpDir()
        try makeDir(dir + "/src")
        try makeDir(dir + "/tests")
        try writeFile(dir + "/README.md")

        let out = try toolOutput(pattern: "*", fileType: "dir", workingDirectory: dir)
        guard out.contains("src") && out.contains("tests") else {
            fatalError("expected directories, got: \(out)")
        }
        guard !out.contains("README.md") else {
            fatalError("unexpected file in dir-only output: \(out)")
        }
    }

    static func testFileTypeFilterAny() throws {
        let dir = tmpDir()
        try makeDir(dir + "/src")
        try writeFile(dir + "/README.md")

        let out = try toolOutput(pattern: "*", fileType: "any", workingDirectory: dir)
        guard out.contains("src") && out.contains("README.md") else {
            fatalError("expected both dir and file, got: \(out)")
        }
    }

    static func testCaseInsensitiveMatching() throws {
        let dir = tmpDir()
        try writeFile(dir + "/Hello.SWIFT")

        let out = try toolOutput(pattern: "hello.swift", caseSensitive: false, workingDirectory: dir)
        guard out.contains("Hello.SWIFT") else {
            fatalError("expected case-insensitive match, got: \(out)")
        }
    }

    static func testEmptyResultIsSuccess() throws {
        let dir = tmpDir()
        try writeFile(dir + "/note.txt")

        let out = try toolOutput(pattern: "*.swift", workingDirectory: dir)
        guard out.contains("[Success]") && out.contains("Found 0 match") else {
            fatalError("expected success with zero matches, got: \(out)")
        }
    }

    static func testMissingBasePathThrows() throws {
        let dir = tmpDir()
        let tool = GlobTool()
        let input = #"{"pattern":"*","path":"does-not-exist"}"#.data(using: .utf8)!
        let context = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: context) }
            fatalError("expected fileNotFound")
        } catch FileSystemError.fileNotFound {
            // expected
        } catch {
            fatalError("expected fileNotFound, got: \(error)")
        }
    }

    static func testSandboxEscapeRejected() throws {
        let dir = tmpDir()
        let tool = GlobTool()
        let input = #"{"pattern":"*","path":"../../../"}"#.data(using: .utf8)!
        let context = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: context) }
            fatalError("expected pathNotSafe")
        } catch FileSystemError.pathNotSafe {
            // expected
        } catch {
            fatalError("expected pathNotSafe, got: \(error)")
        }
    }

    static func testSubpathArgumentRespected() throws {
        let dir = tmpDir()
        try makeDir(dir + "/inside/nested")
        try writeFile(dir + "/inside/nested/in.swift")
        try writeFile(dir + "/outside.swift")

        let out = try toolOutput(pattern: "**/*.swift", path: "inside", workingDirectory: dir)
        guard out.contains("nested/in.swift") else {
            fatalError("expected inside match, got: \(out)")
        }
        guard !out.contains("outside.swift") else {
            fatalError("path scoping leaked outside match: \(out)")
        }
    }

    static func testSchemaShape() throws {
        let tool = GlobTool()
        let schema = tool.parametersJSONSchema
        guard let required = schema["required"] as? [String], required.contains("pattern") else {
            fatalError("schema must require pattern")
        }
        guard let properties = schema["properties"] as? [String: Any],
              let pattern = properties["pattern"] as? [String: Any],
              let fileType = properties["file_type"] as? [String: Any],
              (pattern["type"] as? String) == "string",
              (fileType["type"] as? String) == "string"
        else {
            fatalError("schema must expose string pattern and file_type properties")
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
private enum GlobToolTestRunner {
    static func main() throws {
        try GlobToolTests.main()
    }
}

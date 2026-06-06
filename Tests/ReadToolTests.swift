import Foundation

private final class ReadToolTests {
    static func main() throws {
        try testReadRoundtrip()
        try testReadWithOffsetLimit()
        try testReadMissingFileThrows()
        try testReadSandboxEscapeRejected()
        try testReadEmptyFile()
        try testReadTrailingNewlineDoesNotCountExtraLine()
        try testReadDirectoryRejectedAsNotAFile()
        try testSchemaShape()
        print("ReadToolTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-readtool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func writeFixture(_ dir: String, name: String = "fixture.txt", content: String) -> String {
        let p = dir + "/" + name
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    static func testReadRoundtrip() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "alpha\nbeta\ngamma")
        let tool = ReadTool()
        let input = #"{"file_path":"fixture.txt"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("1→alpha") && out.contains("2→beta") && out.contains("3→gamma") else {
            fatalError("expected line-numbered output, got: \(out)")
        }
    }

    static func testReadWithOffsetLimit() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "a\nb\nc\nd\ne")
        let tool = ReadTool()
        let input = #"{"file_path":"fixture.txt","offset":1,"limit":2}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("2→b") && out.contains("3→c") else {
            fatalError("expected lines 2-3, got: \(out)")
        }
        guard !out.contains("1→a") && !out.contains("4→d") else {
            fatalError("unexpected lines outside offset+limit window: \(out)")
        }
    }

    static func testReadMissingFileThrows() throws {
        let dir = tmpDir()
        let tool = ReadTool()
        let input = #"{"file_path":"does-not-exist.txt"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
            fatalError("expected fileNotFound error")
        } catch FileSystemError.fileNotFound {
            // expected
        } catch {
            fatalError("expected fileNotFound, got: \(error)")
        }
    }

    static func testReadSandboxEscapeRejected() throws {
        let dir = tmpDir()
        let tool = ReadTool()
        let input = #"{"file_path":"../../etc/passwd"}"#.data(using: .utf8)!
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

    static func testReadEmptyFile() throws {
        let dir = tmpDir()
        _ = writeFixture(dir, content: "")
        let tool = ReadTool()
        let input = #"{"file_path":"fixture.txt"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        guard out.contains("Lines: 0 of 0") else {
            fatalError("expected 'Lines: 0 of 0' for empty file, got: \(out)")
        }
        // Must NOT contain a bogus "1→" line-number row.
        guard !out.contains("1→") else {
            fatalError("empty file should not produce any line-numbered rows, got: \(out)")
        }
    }

    static func testReadTrailingNewlineDoesNotCountExtraLine() throws {
        let dir = tmpDir()
        // Three lines of content, each terminated with \n (standard Unix text file).
        _ = writeFixture(dir, content: "alpha\nbeta\ngamma\n")
        let tool = ReadTool()
        let input = #"{"file_path":"fixture.txt"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        let out = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
        // Trailing newline should NOT count as a 4th empty line.
        guard out.contains("Lines: 1-3 of 3") else {
            fatalError("expected 'Lines: 1-3 of 3' for trailing-newline file, got: \(out)")
        }
        // The 4th row "4→" must not appear.
        guard !out.contains("4→") else {
            fatalError("trailing newline incorrectly produced a 4th row, got: \(out)")
        }
    }

    static func testReadDirectoryRejectedAsNotAFile() throws {
        let dir = tmpDir()
        // Create a subdirectory and try to Read it.
        let subdir = dir + "/subdir"
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        let tool = ReadTool()
        let input = #"{"file_path":"subdir"}"#.data(using: .utf8)!
        let ctx = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: ctx) }
            fatalError("expected notAFile error for directory")
        } catch FileSystemError.notAFile {
            // expected
        } catch {
            fatalError("expected notAFile, got: \(error)")
        }
    }

    static func testSchemaShape() throws {
        let tool = ReadTool()
        let schema = tool.parametersJSONSchema
        guard let required = schema["required"] as? [String], required.contains("file_path") else {
            fatalError("schema must require file_path")
        }
        guard let props = schema["properties"] as? [String: Any],
              let fp = props["file_path"] as? [String: Any],
              (fp["type"] as? String) == "string"
        else {
            fatalError("schema.properties.file_path.type must be string")
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
private enum ReadToolTestRunner {
    static func main() throws {
        try ReadToolTests.main()
    }
}

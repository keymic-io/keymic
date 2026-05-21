import Foundation

private final class GrepToolTests {
    static func main() throws {
        try testFilesWithMatchesDefault()
        try testContentModeShowsMatchingLines()
        try testContentModeWithLineNumbers()
        try testCountMode()
        try testGlobFilter()
        try testCaseInsensitive()
        try testMultilineMode()
        try testMultilineModeIncludesContext()
        try testBeforeAfterContext()
        try testHeadLimitAndOffset()
        try testEmptyResultIsSuccess()
        try testSandboxEscapeRejected()
        try testInvalidRegexThrows()
        try testReadErrorsCollected()
        try testDefaultGlobIncludesTopLevelFiles()
        try testSymlinkEscapeFiltered()
        try testSymlinkInsideWorkspaceIsReadSafely()
        try testTinyTruncationHonorsMaxOutputBytes()
        try testSchemaShape()
        print("GrepToolTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-greptool-\(UUID().uuidString)")
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

    @discardableResult
    static func writeBinaryFile(_ path: String, bytes: [UInt8]) throws -> String {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    static func toolOutput(
        pattern: String,
        path: String? = nil,
        glob: String? = nil,
        outputMode: String? = nil,
        caseSensitive: Bool? = nil,
        multiline: Bool? = nil,
        beforeContext: Int? = nil,
        afterContext: Int? = nil,
        contextValue: Int? = nil,
        showLineNumbers: Bool? = nil,
        headLimit: Int? = nil,
        offset: Int? = nil,
        workingDirectory: String,
        maxOutputBytes: Int = 1_048_576,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> String {
        var payload: [String: Any] = ["pattern": pattern]
        if let path { payload["path"] = path }
        if let glob { payload["glob"] = glob }
        if let outputMode { payload["output_mode"] = outputMode }
        if let caseSensitive { payload["case_sensitive"] = caseSensitive }
        if let multiline { payload["multiline"] = multiline }
        if let beforeContext { payload["before_context"] = beforeContext }
        if let afterContext { payload["after_context"] = afterContext }
        if let contextValue { payload["context"] = contextValue }
        if let showLineNumbers { payload["show_line_numbers"] = showLineNumbers }
        if let headLimit { payload["head_limit"] = headLimit }
        if let offset { payload["offset"] = offset }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let tool = GrepTool()
        let context = ToolContext(
            workingDirectory: workingDirectory,
            maxOutputBytes: maxOutputBytes,
            isCancelled: isCancelled
        )
        return try runAsyncThrowing { try await tool.call(argumentsJSON: data, context: context) }
    }

    static func resultLines(_ output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard lines.count > 4 else { return [] }
        return Array(lines.dropFirst(4)).filter { !$0.isEmpty }
    }

    static func testFilesWithMatchesDefault() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "let answer = 42\n")
        try writeFile(dir + "/b.swift", "let question = 42\n")
        try writeFile(dir + "/c.txt", "answer me\n")

        let out = try toolOutput(pattern: "answer", workingDirectory: dir)
        guard out.contains("[Success]") else { fatalError("expected success banner: \(out)") }
        guard out.contains("a.swift") && out.contains("c.txt") else {
            fatalError("expected matching files, got: \(out)")
        }
        guard !out.contains("b.swift") else {
            fatalError("unexpected non-matching file, got: \(out)")
        }
    }

    static func testContentModeShowsMatchingLines() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "first\nmatch here\nthird\n")

        let out = try toolOutput(pattern: "match", outputMode: "content", workingDirectory: dir)
        guard out.contains("match here") else { fatalError("expected matching line, got: \(out)") }
        guard !out.contains("first") && !out.contains("third") else {
            fatalError("unexpected non-context lines in content mode: \(out)")
        }
    }

    static func testContentModeWithLineNumbers() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "first\nsecond match\nthird\n")

        let out = try toolOutput(pattern: "match", outputMode: "content", workingDirectory: dir)
        guard out.contains("2→second match") else {
            fatalError("expected line-number prefix for match, got: \(out)")
        }
    }

    static func testCountMode() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "x\nxx\n")
        try writeFile(dir + "/b.swift", "x only\n")

        let out = try toolOutput(pattern: "x", outputMode: "count", workingDirectory: dir)
        guard out.contains("a.swift: 2") && out.contains("b.swift: 1") else {
            fatalError("expected per-file counts, got: \(out)")
        }
    }

    static func testGlobFilter() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "answer\n")
        try writeFile(dir + "/b.txt", "answer\n")

        let out = try toolOutput(pattern: "answer", glob: "*.swift", workingDirectory: dir)
        guard out.contains("a.swift") else { fatalError("expected swift match, got: \(out)") }
        guard !out.contains("b.txt") else { fatalError("glob filter should exclude txt, got: \(out)") }
    }

    static func testCaseInsensitive() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "TODO: ship it\n")

        let out = try toolOutput(pattern: "todo", caseSensitive: false, workingDirectory: dir)
        guard out.contains("a.swift") else {
            fatalError("expected case-insensitive match, got: \(out)")
        }
    }

    static func testMultilineMode() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "struct Foo {\n    func bar() {}\n}\n")

        let out = try toolOutput(
            pattern: "struct[\\s\\S]*?bar",
            outputMode: "content",
            multiline: true,
            workingDirectory: dir
        )
        guard out.contains("struct Foo") && out.contains("bar") else {
            fatalError("expected multiline match content, got: \(out)")
        }
    }

    static func testMultilineModeIncludesContext() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "intro\nstruct Foo {\n    func bar() {}\n}\noutro\n")

        let out = try toolOutput(
            pattern: "struct[\\s\\S]*?bar",
            outputMode: "content",
            multiline: true,
            beforeContext: 1,
            afterContext: 1,
            workingDirectory: dir
        )
        guard out.contains("1: intro") else {
            fatalError("expected multiline before-context line, got: \(out)")
        }
        guard out.contains("2→struct Foo {") && out.contains("3→    func bar() {}") else {
            fatalError("expected multiline match lines to be marked, got: \(out)")
        }
        guard out.contains("4: }") else {
            fatalError("expected multiline after-context line, got: \(out)")
        }
        guard !out.contains("5: outro") else {
            fatalError("unexpected line outside requested multiline context, got: \(out)")
        }
    }

    static func testBeforeAfterContext() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.txt", "alpha\nbeta\ngamma TARGET\ndelta\nepsilon\n")

        let out = try toolOutput(
            pattern: "TARGET",
            outputMode: "content",
            beforeContext: 1,
            afterContext: 1,
            workingDirectory: dir
        )
        guard out.contains("2: beta") && out.contains("3→gamma TARGET") && out.contains("4: delta") else {
            fatalError("expected before/after context lines, got: \(out)")
        }
        guard !out.contains("1: alpha") && !out.contains("5: epsilon") else {
            fatalError("unexpected extra context lines, got: \(out)")
        }
    }

    static func testHeadLimitAndOffset() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "answer\n")
        try writeFile(dir + "/b.swift", "answer\n")
        try writeFile(dir + "/c.swift", "answer\n")
        try writeFile(dir + "/d.swift", "answer\n")

        let out = try toolOutput(pattern: "answer", headLimit: 2, offset: 1, workingDirectory: dir)
        let lines = resultLines(out)
        guard lines == ["b.swift", "c.swift"] else {
            fatalError("expected paginated sorted output, got: \(out)")
        }
    }

    static func testEmptyResultIsSuccess() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", "nothing here\n")

        let out = try toolOutput(pattern: "answer", workingDirectory: dir)
        guard out.contains("[Success]") && out.contains("Found 0 match") else {
            fatalError("expected success with zero matches, got: \(out)")
        }
    }

    static func testSandboxEscapeRejected() throws {
        let dir = tmpDir()
        let tool = GrepTool()
        let input = #"{"pattern":"answer","path":"../../../"}"#.data(using: .utf8)!
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

    static func testInvalidRegexThrows() throws {
        let dir = tmpDir()
        let tool = GrepTool()
        let input = #"{"pattern":"[unterminated","path":"."}"#.data(using: .utf8)!
        let context = ToolContext(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await tool.call(argumentsJSON: input, context: context) }
            fatalError("expected invalid regex to throw")
        } catch let error as NSError {
            guard !error.domain.isEmpty else {
                fatalError("expected regex-related NSError, got: \(error)")
            }
        } catch {
            fatalError("expected regex error, got: \(error)")
        }
    }

    static func testReadErrorsCollected() throws {
        let dir = tmpDir()
        try writeFile(dir + "/ok.txt", "answer\n")
        try writeBinaryFile(dir + "/bad.bin", bytes: [0, 159, 146, 150])

        let out = try toolOutput(pattern: "answer", workingDirectory: dir)
        guard out.contains("ok.txt") else { fatalError("expected readable match, got: \(out)") }
        let lowercased = out.lowercased()
        guard lowercased.contains("read errors") || lowercased.contains("read error") else {
            fatalError("expected collected read error suffix, got: \(out)")
        }
    }

    static func testDefaultGlobIncludesTopLevelFiles() throws {
        let dir = tmpDir()
        try writeFile(dir + "/top.txt", "needle\n")
        try makeDir(dir + "/nested")
        try writeFile(dir + "/nested/deep.txt", "needle\n")

        let out = try toolOutput(pattern: "needle", workingDirectory: dir)
        guard out.contains("top.txt") && out.contains("nested/deep.txt") else {
            fatalError("default glob should include top-level and nested files, got: \(out)")
        }
    }

    static func testSymlinkEscapeFiltered() throws {
        let dir = tmpDir()
        try writeFile(dir + "/local.txt", "answer\n")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-grep-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try "answer".write(to: secret, atomically: true, encoding: .utf8)

        do {
            try FileManager.default.createSymbolicLink(
                atPath: dir + "/linked-secret.txt",
                withDestinationPath: secret.path
            )
        } catch {
            print("Skipping symlink assertion; createSymbolicLink failed: \(error)")
            return
        }

        let out = try toolOutput(pattern: "answer", workingDirectory: dir)
        guard out.contains("local.txt") else { fatalError("expected local match, got: \(out)") }
        guard !out.contains("linked-secret.txt") else {
            fatalError("symlink escape should be filtered, got: \(out)")
        }
    }

    static func testSymlinkInsideWorkspaceIsReadSafely() throws {
        let dir = tmpDir()
        try makeDir(dir + "/targets")
        try writeFile(dir + "/targets/real.txt", "safe answer\n")

        do {
            try FileManager.default.createSymbolicLink(
                atPath: dir + "/linked-real.txt",
                withDestinationPath: dir + "/targets/real.txt"
            )
        } catch {
            print("Skipping safe symlink assertion; createSymbolicLink failed: \(error)")
            return
        }

        let out = try toolOutput(pattern: "safe answer", path: "linked-real.txt", workingDirectory: dir)
        guard out.contains("linked-real.txt") else {
            fatalError("expected safe symlink base file to be searched, got: \(out)")
        }
    }

    static func testTinyTruncationHonorsMaxOutputBytes() throws {
        let dir = tmpDir()
        try writeFile(dir + "/a.swift", String(repeating: "界answer\n", count: 20))

        let out = try toolOutput(pattern: "answer", outputMode: "content", workingDirectory: dir, maxOutputBytes: 19)
        guard let data = out.data(using: .utf8), data.count <= 19 else {
            fatalError("truncated output exceeds byte limit: \(out)")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            fatalError("truncated output is not valid UTF-8")
        }
    }

    static func testSchemaShape() throws {
        let schema = GrepTool().parametersJSONSchema
        guard let required = schema["required"] as? [String], required.contains("pattern") else {
            fatalError("schema must require pattern")
        }
        guard let properties = schema["properties"] as? [String: Any],
              let pattern = properties["pattern"] as? [String: Any],
              let outputMode = properties["output_mode"] as? [String: Any],
              (pattern["type"] as? String) == "string",
              (outputMode["type"] as? String) == "string"
        else {
            fatalError("schema must expose string pattern and output_mode properties")
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
private enum GrepToolTestRunner {
    static func main() throws {
        try GrepToolTests.main()
    }
}

import Foundation

private final class FileSystemActorTests {
    static func main() throws {
        try testNormalizeAbsolutePath()
        try testNormalizeRelativePath()
        try testIsPathSafeWithinSandbox()
        try testIsPathSafeRejectsEscape()
        try testReadWriteRoundtrip()
        try testWriteCreatesParentDir()
        try testBinaryDetection()
        print("FileSystemActorTests passed")
    }

    static func tmpDir() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-fsactor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func testNormalizeAbsolutePath() throws {
        let fs = FileSystemActor(workingDirectory: "/tmp/work")
        let p = runAsync { await fs.normalizePath("/absolute/file") }
        guard p == "/absolute/file" else { fatalError("expected /absolute/file, got \(p)") }
    }

    static func testNormalizeRelativePath() throws {
        let fs = FileSystemActor(workingDirectory: "/tmp/work")
        let p = runAsync { await fs.normalizePath("sub/file.txt") }
        guard p == "/tmp/work/sub/file.txt" else { fatalError("expected /tmp/work/sub/file.txt, got \(p)") }
    }

    static func testIsPathSafeWithinSandbox() throws {
        let dir = tmpDir()
        let fs = FileSystemActor(workingDirectory: dir)
        let inside = runAsync { await fs.normalizePath("inside.txt") }
        let safe = runAsync { await fs.isPathSafe(inside) }
        guard safe else { fatalError("expected inside path to be safe") }
    }

    static func testIsPathSafeRejectsEscape() throws {
        let dir = tmpDir()
        let fs = FileSystemActor(workingDirectory: dir)
        let escape = runAsync { await fs.normalizePath("../../etc/passwd") }
        let safe = runAsync { await fs.isPathSafe(escape) }
        guard !safe else { fatalError("expected escape path to be unsafe") }
    }

    static func testReadWriteRoundtrip() throws {
        let dir = tmpDir()
        let fs = FileSystemActor(workingDirectory: dir)
        let target = dir + "/sample.txt"
        try runAsyncThrowing { try await fs.writeFile(content: "hello\nworld", toPath: target) }
        let read = try runAsyncThrowing { try await fs.readFile(atPath: target) }
        guard read == "hello\nworld" else { fatalError("roundtrip mismatch: \(read)") }
    }

    static func testWriteCreatesParentDir() throws {
        let dir = tmpDir()
        let fs = FileSystemActor(workingDirectory: dir)
        let target = dir + "/nested/deep/file.txt"
        try runAsyncThrowing { try await fs.writeFile(content: "x", toPath: target) }
        guard FileManager.default.fileExists(atPath: target) else { fatalError("parent dir not created") }
    }

    static func testBinaryDetection() throws {
        let fs = FileSystemActor(workingDirectory: "/tmp")
        let textOK = runAsync { await fs.isBinaryData("hello".data(using: .utf8)!) }
        guard !textOK else { fatalError("plain text flagged as binary") }
        let binData = Data([0x00, 0x01, 0xFF, 0x00])
        let binFlagged = runAsync { await fs.isBinaryData(binData) }
        guard binFlagged else { fatalError("null-byte data not flagged as binary") }
    }

    static func runAsync<T>(_ work: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var out: T!
        Task { out = await work(); semaphore.signal() }
        semaphore.wait()
        return out
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
private enum FileSystemActorTestRunner {
    static func main() throws {
        try FileSystemActorTests.main()
    }
}

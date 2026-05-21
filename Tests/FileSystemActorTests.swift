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
        try testReadFileTooLarge()
        try testWriteContentTooLarge()
        try testReadBinaryFileRejected()
        try testReadInvalidUTF8Rejected()
        try testIsPathSafeRejectsSymlinkEscape()
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
        let textOK = FileSystemActor.isBinaryData("hello".data(using: .utf8)!)
        guard !textOK else { fatalError("plain text flagged as binary") }
        let binData = Data([0x00, 0x01, 0xFF, 0x00])
        let binFlagged = FileSystemActor.isBinaryData(binData)
        guard binFlagged else { fatalError("null-byte data not flagged as binary") }
    }

    static func testReadFileTooLarge() throws {
        let dir = tmpDir()
        let target = dir + "/big.txt"
        // 1 MB + 1 byte of valid ASCII content
        let oversized = String(repeating: "a", count: Int(FileSystemActor.maxFileSize) + 1)
        try oversized.write(toFile: target, atomically: true, encoding: .utf8)
        let fs = FileSystemActor(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await fs.readFile(atPath: target) }
            fatalError("expected fileTooLarge")
        } catch FileSystemError.fileTooLarge {
            // expected
        } catch {
            fatalError("expected fileTooLarge, got: \(error)")
        }
    }

    static func testWriteContentTooLarge() throws {
        let dir = tmpDir()
        let fs = FileSystemActor(workingDirectory: dir)
        let oversized = String(repeating: "a", count: Int(FileSystemActor.maxFileSize) + 1)
        do {
            try runAsyncThrowing { try await fs.writeFile(content: oversized, toPath: dir + "/big.txt") }
            fatalError("expected contentTooLarge")
        } catch FileSystemError.contentTooLarge {
            // expected
        } catch {
            fatalError("expected contentTooLarge, got: \(error)")
        }
    }

    static func testReadBinaryFileRejected() throws {
        let dir = tmpDir()
        let target = dir + "/bin.bin"
        // Write data with a null byte directly (bypassing FileSystemActor's writeFile,
        // which would reject the encoding — we want a real on-disk binary file).
        try Data([0x48, 0x00, 0x49]).write(to: URL(fileURLWithPath: target))
        let fs = FileSystemActor(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await fs.readFile(atPath: target) }
            fatalError("expected binaryFileDetected")
        } catch FileSystemError.binaryFileDetected {
            // expected
        } catch {
            fatalError("expected binaryFileDetected, got: \(error)")
        }
    }

    static func testReadInvalidUTF8Rejected() throws {
        let dir = tmpDir()
        let target = dir + "/bad.txt"
        // A stray 0xC0 0xC1 sequence is invalid UTF-8 in any context, with no
        // null/control bytes that would trip binary detection first.
        try Data([0x48, 0xC0, 0xC1, 0x49]).write(to: URL(fileURLWithPath: target))
        let fs = FileSystemActor(workingDirectory: dir)
        do {
            _ = try runAsyncThrowing { try await fs.readFile(atPath: target) }
            fatalError("expected invalidEncoding")
        } catch FileSystemError.invalidEncoding {
            // expected
        } catch FileSystemError.binaryFileDetected {
            // also acceptable — 0xC0/0xC1 may be classified as binary on some
            // implementations of the byte-range check, but the test below
            // confirms the invariant: somewhere in the read pipeline non-UTF-8
            // bytes are rejected (either path is fine for safety).
        } catch {
            fatalError("expected invalidEncoding or binaryFileDetected, got: \(error)")
        }
    }

    static func testIsPathSafeRejectsSymlinkEscape() throws {
        let dir = tmpDir()
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-outside-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        // Create a symlink inside the sandbox pointing OUTSIDE.
        let symlinkPath = dir + "/escape"
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath,
            withDestinationPath: outsideDir.path
        )

        let fs = FileSystemActor(workingDirectory: dir)
        // Access something "through" the symlink — should resolve outside the
        // sandbox and isPathSafe must reject.
        let target = runAsync { await fs.normalizePath("escape/leaked.txt") }
        let safe = runAsync { await fs.isPathSafe(target) }
        guard !safe else {
            fatalError("symlink-escape path \(target) wrongly classified as safe")
        }
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

import Foundation

private final class ShellSnapshotTests {
    static func main() throws {
        try testEnsureFreshFirstCall()
        try testCacheReturnsSamePath()
        try testMtimeChangeTriggersRebuild()
        try testDumpFailureReturnsNil()
        try testStaleSnapshotKeptOnRebuildFailure()
        try testOldSnapshotsCleanedUp()
        try testFilePermissions0600()
        try testConcurrentEnsureFreshSerializes()
        print("ShellSnapshotTests passed")
    }

    static func makeFixture() throws -> (URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-snap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zshrc = tmp.appendingPathComponent(".zshrc-fixture")
        try "# fixture".write(to: zshrc, atomically: true, encoding: .utf8)
        return (tmp, zshrc)
    }

    final class DumpRecorder {
        var calls = 0
        var nextResult: (Int32, String, String) = (0, "", "")
        var snapshotContent: String = "# stub snapshot\n"
        func run(shell: String, script: String) -> (Int32, String, String) {
            calls += 1
            // Extract snapshot path from SNAPSHOT_FILE='...' in the dump script
            if let range = script.range(of: "SNAPSHOT_FILE='"),
               let endRange = script[range.upperBound...].range(of: "'") {
                let path = String(script[range.upperBound..<endRange.lowerBound])
                if nextResult.0 == 0 {
                    try? snapshotContent.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            return nextResult
        }
    }

    static func testEnsureFreshFirstCall() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let snapDir = tmp.appendingPathComponent("snaps")
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: snapDir, watched: [zshrc],
                                  dumpRunner: recorder.run, shellPath: "/bin/zsh")
        guard let url = snap.ensureFresh() else { fatalError("ensureFresh returned nil") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            fatalError("snapshot file not created at \(url.path)")
        }
        guard recorder.calls == 1 else { fatalError("expected 1 dump call, got \(recorder.calls)") }
    }

    static func testCacheReturnsSamePath() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: tmp.appendingPathComponent("snaps"),
                                  watched: [zshrc], dumpRunner: recorder.run, shellPath: "/bin/zsh")
        let u1 = snap.ensureFresh()
        let u2 = snap.ensureFresh()
        guard u1 == u2 else { fatalError("paths differ: \(String(describing: u1)) vs \(String(describing: u2))") }
        guard recorder.calls == 1 else { fatalError("expected 1 dump, got \(recorder.calls)") }
    }

    static func testMtimeChangeTriggersRebuild() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: tmp.appendingPathComponent("snaps"),
                                  watched: [zshrc], dumpRunner: recorder.run, shellPath: "/bin/zsh")
        _ = snap.ensureFresh()
        let future = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: zshrc.path)
        _ = snap.ensureFresh()
        guard recorder.calls == 2 else { fatalError("expected 2 dumps, got \(recorder.calls)") }
    }

    static func testDumpFailureReturnsNil() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = DumpRecorder()
        recorder.nextResult = (1, "", "boom")
        let snap = ShellSnapshot(snapshotDir: tmp.appendingPathComponent("snaps"),
                                  watched: [zshrc], dumpRunner: recorder.run, shellPath: "/bin/zsh")
        guard snap.ensureFresh() == nil else { fatalError("expected nil on dump failure") }
    }

    static func testStaleSnapshotKeptOnRebuildFailure() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: tmp.appendingPathComponent("snaps"),
                                  watched: [zshrc], dumpRunner: recorder.run, shellPath: "/bin/zsh")
        guard let first = snap.ensureFresh() else { fatalError("first call returned nil") }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                               ofItemAtPath: zshrc.path)
        recorder.nextResult = (1, "", "boom")
        let second = snap.ensureFresh()
        guard second == first else { fatalError("expected stale URL on rebuild failure, got \(String(describing: second))") }
    }

    static func testOldSnapshotsCleanedUp() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let snapDir = tmp.appendingPathComponent("snaps")
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        for i in 0..<3 {
            try "stale".write(to: snapDir.appendingPathComponent("old-\(i).sh"),
                              atomically: true, encoding: .utf8)
        }
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: snapDir, watched: [zshrc],
                                  dumpRunner: recorder.run, shellPath: "/bin/zsh")
        _ = snap.ensureFresh()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: snapDir.path)
        guard remaining.count == 1 else { fatalError("expected 1 file, got \(remaining)") }
    }

    static func testFilePermissions0600() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: tmp.appendingPathComponent("snaps"),
                                  watched: [zshrc], dumpRunner: recorder.run, shellPath: "/bin/zsh")
        guard let url = snap.ensureFresh() else { fatalError("ensureFresh returned nil") }
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        guard perms?.intValue == 0o600 else {
            fatalError("expected 0o600, got \(String(describing: perms))")
        }
    }

    static func testConcurrentEnsureFreshSerializes() throws {
        let (tmp, zshrc) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = DumpRecorder()
        let snap = ShellSnapshot(snapshotDir: tmp.appendingPathComponent("snaps"),
                                  watched: [zshrc], dumpRunner: recorder.run, shellPath: "/bin/zsh")
        let group = DispatchGroup()
        for _ in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                _ = snap.ensureFresh()
                group.leave()
            }
        }
        group.wait()
        guard recorder.calls == 1 else { fatalError("expected 1 dump under concurrency, got \(recorder.calls)") }
    }
}

@main
private enum SnapshotTestRunner {
    static func main() throws {
        try ShellSnapshotTests.main()
    }
}

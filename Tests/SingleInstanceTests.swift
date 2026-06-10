import Foundation

@main
struct SingleInstanceTestRunner {
    static func main() {
        let currentPID = Int32(123)
        let runningApps = [
            RunningApplicationSnapshot(processIdentifier: currentPID, bundleIdentifier: "io.keymic.app"),
            RunningApplicationSnapshot(processIdentifier: 456, bundleIdentifier: "com.example.Other"),
        ]
        expect(SingleInstance.existingInstance(bundleIdentifier: "io.keymic.app", currentProcessIdentifier: currentPID, runningApplications: runningApps) == nil, "current process is ignored")

        let duplicate = RunningApplicationSnapshot(processIdentifier: 789, bundleIdentifier: "io.keymic.app")
        let withDuplicate = runningApps + [duplicate]
        expect(SingleInstance.existingInstance(bundleIdentifier: "io.keymic.app", currentProcessIdentifier: currentPID, runningApplications: withDuplicate)?.processIdentifier == 789, "other process with same bundle id is detected")

        let lockDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("keymic-single-instance-tests-\(UUID().uuidString)", isDirectory: true)
        // acquireLock creates the lock directory itself — do NOT pre-create it here.
        let firstLock = SingleInstance.acquireLock(bundleIdentifier: "io.keymic.app", lockDirectory: lockDirectory)
        expect(firstLock != nil, "first acquirer takes the singleton lock (and creates the lock directory)")
        // flock conflicts between distinct open file descriptions even within one
        // process, so a second acquire here models a second process.
        let secondLock = SingleInstance.acquireLock(bundleIdentifier: "io.keymic.app", lockDirectory: lockDirectory)
        expect(secondLock == nil, "second acquirer cannot take a held lock")
        if let firstLock { SingleInstance.releaseLock(at: firstLock) }
        let thirdLock = SingleInstance.acquireLock(bundleIdentifier: "io.keymic.app", lockDirectory: lockDirectory)
        expect(thirdLock != nil, "lock can be reacquired after release")
        if let thirdLock { SingleInstance.releaseLock(at: thirdLock) }

        // A leftover lock file with no live flock (crash/SIGKILL residue — the
        // kernel dropped the lock with the dead process's fd) must be reacquirable.
        let staleFile = lockDirectory.appendingPathComponent("stale.bundle.lock")
        expect(FileManager.default.createFile(atPath: staleFile.path, contents: Data("999999".utf8)), "fixture lock file created")
        let recoveredLock = SingleInstance.acquireLock(bundleIdentifier: "stale.bundle", lockDirectory: lockDirectory)
        expect(recoveredLock != nil, "unlocked leftover lock file is acquired")
        if let recoveredLock { SingleInstance.releaseLock(at: recoveredLock) }
        try? FileManager.default.removeItem(at: lockDirectory)

        print("SingleInstanceTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

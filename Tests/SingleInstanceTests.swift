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
        try! FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let livePID = ProcessInfo.processInfo.processIdentifier
        let firstLock = SingleInstance.acquireLock(bundleIdentifier: "io.keymic.app", currentProcessIdentifier: livePID, lockDirectory: lockDirectory)
        expect(firstLock != nil, "first process acquires singleton lock")
        let secondLock = SingleInstance.acquireLock(bundleIdentifier: "io.keymic.app", currentProcessIdentifier: 456, lockDirectory: lockDirectory)
        expect(secondLock == nil, "second process cannot acquire singleton lock")
        if let firstLock { SingleInstance.releaseLock(at: firstLock) }
        let thirdLock = SingleInstance.acquireLock(bundleIdentifier: "io.keymic.app", currentProcessIdentifier: 456, lockDirectory: lockDirectory)
        expect(thirdLock != nil, "lock can be reacquired after release")
        if let thirdLock { SingleInstance.releaseLock(at: thirdLock) }

        let staleLock = lockDirectory.appendingPathComponent("stale.bundle.lock", isDirectory: true)
        try! FileManager.default.createDirectory(at: staleLock, withIntermediateDirectories: false)
        try! "999999".write(to: staleLock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        let recoveredLock = SingleInstance.acquireLock(bundleIdentifier: "stale.bundle", currentProcessIdentifier: 456, lockDirectory: lockDirectory)
        expect(recoveredLock != nil, "stale lock is replaced")
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

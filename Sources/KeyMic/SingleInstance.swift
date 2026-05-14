import AppKit
import Foundation

struct RunningApplicationSnapshot: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

enum SingleInstance {
    static func acquireLock(
        bundleIdentifier: String,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        lockDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let lockURL = lockDirectory.appendingPathComponent("\(bundleIdentifier).lock", isDirectory: true)
        if createLock(at: lockURL, currentProcessIdentifier: currentProcessIdentifier) {
            return lockURL
        }
        if isStaleLock(at: lockURL) {
            releaseLock(at: lockURL)
            if createLock(at: lockURL, currentProcessIdentifier: currentProcessIdentifier) {
                return lockURL
            }
        }
        return nil
    }

    static func releaseLock(at lockURL: URL) {
        try? FileManager.default.removeItem(at: lockURL)
    }

    private static func createLock(at lockURL: URL, currentProcessIdentifier: pid_t) -> Bool {
        do {
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
            let pidURL = lockURL.appendingPathComponent("pid")
            try "\(currentProcessIdentifier)".write(to: pidURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func isStaleLock(at lockURL: URL) -> Bool {
        let pidURL = lockURL.appendingPathComponent("pid")
        guard let content = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    static func existingInstance(
        bundleIdentifier: String,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        runningApplications: [RunningApplicationSnapshot] = NSWorkspace.shared.runningApplications.map {
            RunningApplicationSnapshot(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
        }
    ) -> RunningApplicationSnapshot? {
        runningApplications.first {
            $0.processIdentifier != currentProcessIdentifier && $0.bundleIdentifier == bundleIdentifier
        }
    }
}

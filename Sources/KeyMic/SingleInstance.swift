import AppKit
import Foundation

struct RunningApplicationSnapshot: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

/// Single-instance guard backed by a real `flock(2)` on a file in
/// `~/Library/Application Support/KeyMic/`. The kernel makes acquisition
/// atomic (no mkdir/write-pid TOCTOU window) and releases the lock
/// automatically when the holder's fd closes — including crash/SIGKILL —
/// so there is no stale-pid detection and no pid-reuse false positive.
/// The lock file itself is never meaningful on disk: only a live flock is.
enum SingleInstance {
    /// fd per acquired lock URL, held open for the lifetime of the process.
    private static var lockFileDescriptors: [URL: Int32] = [:]

    static func defaultLockDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyMic", isDirectory: true)
    }

    static func acquireLock(
        bundleIdentifier: String,
        lockDirectory: URL = defaultLockDirectory()
    ) -> URL? {
        let lockURL = lockDirectory.appendingPathComponent("\(bundleIdentifier).lock")
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        lockFileDescriptors[lockURL] = fd
        return lockURL
    }

    static func releaseLock(at lockURL: URL) {
        guard let fd = lockFileDescriptors.removeValue(forKey: lockURL) else { return }
        flock(fd, LOCK_UN)
        close(fd)
        // The file is left on disk intentionally: deleting it would let a
        // concurrent starter recreate-and-lock a *different* inode while a
        // third process still locks the old one.
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

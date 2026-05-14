import Foundation
import os

struct ShellLogEntry {
    let timestamp: Date
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let durationMs: Int
    let fallback: Bool
}

class ShellLogger {
    static let shared = ShellLogger()

    private let queue = DispatchQueue(label: "io.keymic.app.shell-logger")
    private let logURL: URL
    private let maxBytes: Int
    private let osLogger = Logger(subsystem: "io.keymic.app", category: "ShellLogger")
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(logURL: URL? = nil, maxBytes: Int = 5 * 1024 * 1024) {
        if let logURL = logURL {
            self.logURL = logURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.logURL = home.appendingPathComponent("Library/Logs/KeyMic.log")
        }
        self.maxBytes = maxBytes
    }

    func log(_ entry: ShellLogEntry) {
        queue.async { [self] in
            do {
                try rotateIfNeeded()
                let line = format(entry)
                try append(line)
            } catch {
                osLogger.error("ShellLogger write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flushForTesting() {
        queue.sync { }
    }

    private func rotateIfNeeded() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logURL.path) else { return }
        let attrs = try fm.attributesOfItem(atPath: logURL.path)
        guard let size = attrs[.size] as? Int, size > maxBytes else { return }
        let backupURL = logURL.appendingPathExtension("1")
        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }
        try fm.moveItem(at: logURL, to: backupURL)
    }

    private func format(_ e: ShellLogEntry) -> String {
        let ts = isoFormatter.string(from: e.timestamp)
        let fallbackMark = e.fallback ? " (fallback)" : ""
        var out = "[Shell] \(ts) exit=\(e.exitCode) duration=\(e.durationMs)ms\(fallbackMark) cmd: \(e.command)\n"
        if !e.stdout.isEmpty {
            out += "[Shell]   stdout: \(String(e.stdout.prefix(4096)))\n"
        }
        if !e.stderr.isEmpty {
            out += "[Shell]   stderr: \(String(e.stderr.prefix(4096)))\n"
        }
        return out
    }

    private func append(_ line: String) throws {
        let fm = FileManager.default
        let dir = logURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }
}

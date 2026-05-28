import Foundation
import os

final class ShellSnapshot {
    static let shared = ShellSnapshot()

    typealias DumpRunner = (_ shell: String, _ script: String) -> (Int32, String, String)

    private let lock = NSLock()
    private var currentPath: URL?
    private var sourceMtimes: [URL: Date] = [:]
    private let osLogger = Logger(subsystem: "io.keymic.app", category: "ShellSnapshot")

    private let snapshotDir: URL
    private let watched: [URL]
    private let dumpRunner: DumpRunner
    private let shellPath: String

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/KeyMic/shell-snapshots")
        let shell = ShellSnapshot.resolveShell()
        let watched: [URL]
        if shell.contains("zsh") {
            watched = [".zshrc", ".zprofile", ".zshenv"].map { home.appendingPathComponent($0) }
        } else if shell.contains("bash") {
            watched = [".bashrc", ".bash_profile", ".profile"].map { home.appendingPathComponent($0) }
        } else {
            watched = [home.appendingPathComponent(".profile")]
        }
        self.init(snapshotDir: dir, watched: watched,
                  dumpRunner: ShellSnapshot.defaultDumpRunner, shellPath: shell)
    }

    init(snapshotDir: URL, watched: [URL], dumpRunner: @escaping DumpRunner, shellPath: String) {
        self.snapshotDir = snapshotDir
        self.watched = watched
        self.dumpRunner = dumpRunner
        self.shellPath = shellPath
    }

    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = ensureFresh()
        }
    }

    func ensureFresh() -> URL? {
        lock.lock()
        if let path = currentPath, !FileManager.default.fileExists(atPath: path.path) {
            currentPath = nil
            sourceMtimes = [:]
        }
        let needsRebuild = currentPath == nil || mtimesChanged()
        if !needsRebuild {
            let path = currentPath
            lock.unlock()
            return path
        }
        lock.unlock()

        // Rebuild outside the lock so callers don't block during subprocess spawn
        let newPath = try? rebuild()

        lock.lock()
        defer { lock.unlock() }
        if let newPath {
            sourceMtimes = currentMtimes()
            cleanupOld(keeping: newPath)
            currentPath = newPath
        }
        return currentPath
    }

    private func rebuild() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let shellName = (shellPath as NSString).lastPathComponent
        let pid = ProcessInfo.processInfo.processIdentifier
        let ts = Int(Date().timeIntervalSince1970)
        let snapshotPath = snapshotDir.appendingPathComponent("snapshot-\(shellName)-\(pid)-\(ts).sh")

        let script = makeDumpScript(snapshotPath: snapshotPath, shellName: shellName)
        let (exit, _, stderr) = dumpRunner(shellPath, script)
        guard exit == 0 else {
            osLogger.warning("dump exit=\(exit) stderr=\(String(stderr.prefix(4096)), privacy: .public)")
            throw NSError(domain: "ShellSnapshot", code: Int(exit),
                          userInfo: [NSLocalizedDescriptionKey: "dump exit \(exit)"])
        }
        guard fm.fileExists(atPath: snapshotPath.path) else {
            throw NSError(domain: "ShellSnapshot", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "snapshot file missing after dump"])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotPath.path)
        return snapshotPath
    }

    private func currentMtimes() -> [URL: Date] {
        var result: [URL: Date] = [:]
        for url in watched {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date {
                result[url] = mtime
            }
        }
        return result
    }

    private func mtimesChanged() -> Bool {
        currentMtimes() != sourceMtimes
    }

    private func cleanupOld(keeping: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.standardizedFileURL != keeping.standardizedFileURL {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func makeDumpScript(snapshotPath: URL, shellName: String) -> String {
        let quotedSnap = posixQuote(snapshotPath.path)
        let isZsh = shellName.contains("zsh")
        let configFile = isZsh ? "~/.zshrc" : "~/.bashrc"

        let funcsBlock: String
        let optionsBlock: String
        let extraBlock: String
        if isZsh {
            funcsBlock = """
            typeset -f > /dev/null 2>&1
            typeset +f 2>/dev/null | grep -vE '^_[^_]' | while read func; do
              typeset -f "$func" >> "$SNAPSHOT_FILE"
            done
            """
            optionsBlock = #"setopt 2>/dev/null | sed 's/^/setopt /' | head -n 1000 >> "$SNAPSHOT_FILE""#
            extraBlock = #"echo 'setopt NO_EXTENDED_GLOB 2>/dev/null || true' >> "$SNAPSHOT_FILE""#
        } else {
            funcsBlock = """
            declare -F 2>/dev/null | cut -d' ' -f3 | grep -vE '^_[^_]' | while read func; do
              encoded=$(declare -f "$func" | base64 | tr -d '\\n')
              printf 'eval "$(echo %s | base64 -d)" > /dev/null 2>&1\\n' "$encoded" >> "$SNAPSHOT_FILE"
            done
            """
            optionsBlock = """
            shopt -p 2>/dev/null | head -n 1000 >> "$SNAPSHOT_FILE"
            set -o 2>/dev/null | awk '$2=="on"{print "set -o " $1}' | head -n 1000 >> "$SNAPSHOT_FILE"
            echo 'shopt -s expand_aliases' >> "$SNAPSHOT_FILE"
            """
            extraBlock = #"echo 'shopt -u extglob 2>/dev/null || true' >> "$SNAPSHOT_FILE""#
        }

        return """
        SNAPSHOT_FILE=\(quotedSnap)
        source \(configFile) < /dev/null 2>/dev/null || true
        echo "# KeyMic shell snapshot" >| "$SNAPSHOT_FILE"
        echo "unalias -a 2>/dev/null || true" >> "$SNAPSHOT_FILE"
        \(funcsBlock)
        \(optionsBlock)
        alias 2>/dev/null | sed 's/^alias //' | sed 's/^/alias -- /' | head -n 1000 >> "$SNAPSHOT_FILE"
        printf 'export PATH=%q\\n' "$PATH" >> "$SNAPSHOT_FILE"
        \(extraBlock)
        """
    }

    private func posixQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func resolveShell() -> String {
        if let env = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        return "/bin/zsh"
    }

    private static func defaultDumpRunner(shellPath: String, script: String) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shellPath)
        p.arguments = ["-l", "-c", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var stdoutData = Data()
        var stderrData = Data()
        let outQ = DispatchQueue(label: "snap-out")
        let errQ = DispatchQueue(label: "snap-err")
        outPipe.fileHandleForReading.readabilityHandler = { h in
            outQ.sync { stdoutData.append(h.availableData) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            errQ.sync { stderrData.append(h.availableData) }
        }

        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "", "Process.run failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 1.0)
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errRemaining = errPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutData.append(remaining)
            stderrData.append(errRemaining)
            let outStr = outQ.sync { String(data: stdoutData, encoding: .utf8) ?? "" }
            let errStr = errQ.sync { String(data: stderrData, encoding: .utf8) ?? "" }
            return (-1, outStr, "snapshot dump timeout: \(errStr)")
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let outStr = outQ.sync { String(data: stdoutData, encoding: .utf8) ?? "" }
        let errStr = errQ.sync { String(data: stderrData, encoding: .utf8) ?? "" }
        return (p.terminationStatus, outStr, errStr)
    }
}

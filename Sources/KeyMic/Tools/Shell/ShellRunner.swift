import Foundation
import os

final class ShellRunner {
    static let shared = ShellRunner()

    typealias SnapshotProvider = () -> URL?

    private let snapshotProvider: SnapshotProvider
    private let logger: ShellLogger
    private let osLogger = Logger(subsystem: "io.keymic.app", category: "ShellRunner")
    private let shellPath: String
    private let commandTimeout: TimeInterval
    private let sigkillGrace: TimeInterval

    convenience init() {
        self.init(
            snapshotProvider: { ShellSnapshot.shared.ensureFresh() },
            logger: .shared,
            shellPath: ShellRunner.resolveShell(),
            commandTimeout: 30,
            sigkillGrace: 5
        )
    }

    init(
        snapshotProvider: @escaping SnapshotProvider,
        logger: ShellLogger,
        shellPath: String,
        commandTimeout: TimeInterval,
        sigkillGrace: TimeInterval
    ) {
        self.snapshotProvider = snapshotProvider
        self.logger = logger
        self.shellPath = shellPath
        self.commandTimeout = commandTimeout
        self.sigkillGrace = sigkillGrace
    }

    func warmUp() {
        ShellSnapshot.shared.warmUp()
    }

    func run(_ command: String) -> Int32 {
        let t0 = Date()
        let snapshot = snapshotProvider()
        let fallback = (snapshot == nil)

        let args: [String]
        if let snap = snapshot {
            let wrapped = "source \(posixQuote(snap.path)) 2>/dev/null || true; eval \(posixQuote(command))"
            args = ["-c", wrapped]
        } else {
            let wrapped = "eval \(posixQuote(command))"
            args = ["-l", "-c", wrapped]
        }

        let (exit, stdout, stderr) = runProcess(args: args)
        let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
        logger.log(ShellLogEntry(
            timestamp: t0, command: command, exitCode: exit,
            stdout: stdout, stderr: stderr,
            durationMs: durationMs, fallback: fallback
        ))
        return exit
    }

    private func runProcess(args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shellPath)
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var stdoutData = Data()
        var stderrData = Data()
        let outQ = DispatchQueue(label: "runner-out")
        let errQ = DispatchQueue(label: "runner-err")
        outPipe.fileHandleForReading.readabilityHandler = { h in
            outQ.sync { stdoutData.append(h.availableData) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            errQ.sync { stderrData.append(h.availableData) }
        }

        do {
            try p.run()
        } catch {
            return (-1, "", "Process.run failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(commandTimeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            let tree = collectProcessTree(p.processIdentifier)
            for pid in tree { kill(pid, SIGTERM) }
            let killDeadline = Date().addingTimeInterval(sigkillGrace)
            while p.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                for pid in tree { kill(pid, SIGKILL) }
                p.waitUntilExit()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any data the readability handler may not have delivered yet.
        // NOT readDataToEndOfFile(): if the command exited but left a daemonized
        // child that inherited the pipe write end (`my-server &`), EOF never
        // arrives and a blocking read would hang this serial queue forever —
        // killing every subsequent hotkey action. A non-blocking drain returns
        // whatever the kernel buffer holds (≤64 KB) and bails on EAGAIN.
        // Serialize through the same queues to avoid racing a possibly in-flight
        // handler's read on the same fd.
        outQ.sync { stdoutData.append(Self.drainNonBlocking(outPipe.fileHandleForReading)) }
        errQ.sync { stderrData.append(Self.drainNonBlocking(errPipe.fileHandleForReading)) }

        let outStr = outQ.sync { String(data: stdoutData, encoding: .utf8) ?? "" }
        let errStr = errQ.sync { String(data: stderrData, encoding: .utf8) ?? "" }
        return (p.terminationStatus, outStr, errStr)
    }

    /// Sets O_NONBLOCK on the handle's fd and reads until the kernel buffer is
    /// empty (EAGAIN) or EOF. Never blocks, even if another process still holds
    /// the pipe's write end.
    private static func drainNonBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break } // 0 = EOF, -1 = EAGAIN/error — stop either way
            out.append(buf, count: n)
        }
        return out
    }

    private func collectProcessTree(_ rootPid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid,ppid"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [rootPid] }
        // Drain BEFORE waitUntilExit: readDataToEndOfFile blocks until ps closes
        // stdout at exit, so it consumes output concurrently. The old order
        // (waitUntilExit first) deadlocked once ps output exceeded the 64 KB pipe
        // buffer — ps blocked writing, we blocked waiting.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        var children: [Int32: [Int32]] = [:]
        for line in output.components(separatedBy: "\n") {
            let cols = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard cols.count >= 2, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            children[ppid, default: []].append(pid)
        }

        var pids: [Int32] = []
        func collect(_ pid: Int32) {
            pids.append(pid)
            for child in children[pid] ?? [] { collect(child) }
        }
        collect(rootPid)
        return pids
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
}

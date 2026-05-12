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
            let wrapped = "source \(posixQuote(snap.path)) 2>/dev/null && eval \(posixQuote(command))"
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
            p.terminate()  // SIGTERM
            let killDeadline = Date().addingTimeInterval(sigkillGrace)
            while p.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let outStr = outQ.sync { String(data: stdoutData, encoding: .utf8) ?? "" }
        let errStr = errQ.sync { String(data: stderrData, encoding: .utf8) ?? "" }
        return (p.terminationStatus, outStr, errStr)
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

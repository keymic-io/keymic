import Foundation

struct ShellOutputResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellOutputRunnerError: Error, Equatable {
    case launchFailed(String)
    case timeout
}

/// Adapter over `ShellRunner.runAndCapture` for the persona `.runShell` output
/// strategy. Kept as a named type (returning `ShellOutputResult`) so
/// `OutputRouter`'s `runShellExecutor` test seam stays source-compatible.
///
/// cwd is `$HOME` (preserved from the prior raw-Process behavior). The
/// `timeout` parameter is accepted for source compatibility but ignored —
/// `ShellRunner` enforces its own fixed 30s timeout (SIGTERM-tree → SIGKILL);
/// a timed-out command surfaces as a non-zero exit, not a thrown `.timeout`.
/// `KEYMIC_*` env keys are no longer stripped (ShellRunner inherits the full
/// parent env); currently inert as nothing in the app sets them.
enum ShellOutputRunner {
    static func run(_ command: String, timeout: TimeInterval = 30) async throws -> ShellOutputResult {
        let (exit, out, err) = await ShellRunner.shared.runAndCapture(command, cwd: NSHomeDirectory())
        return ShellOutputResult(stdout: out, stderr: err, exitCode: exit)
    }
}

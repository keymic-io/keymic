import Foundation

/// Tool wrapper around ShellRunner. Executes a shell command in the user's
/// shell environment (snapshot-restored), returns combined stdout/stderr
/// plus exit code information.
///
/// Trust model: KeyMic's BashTool inherits ShellRunner's design choice
/// of running through the user's shell (zsh/bash + sourced snapshot). It
/// does NOT use a command whitelist. The trust model is "the LLM has been
/// granted shell access by the user" — same level as the user's hotkey
/// shell actions. Caller is responsible for authorization upstream.
struct BashTool: Tool {
    let name = "Bash"

    let description = """
    Executes a shell command in the user's shell environment.

    The command runs through the user's $SHELL (zsh by default) with the
    user's startup files sourced, so aliases, functions, and PATH
    additions are available. Returns combined stdout/stderr along with
    exit code.

    Usage:
    - Provide the full command line as the `command` argument (e.g.,
      "git status", "ls -la ~/Documents").
    - Pipes, redirects, variables, and shell expansion are supported
      because the command goes through the real shell.
    - There is no command whitelist. Do not run commands the user has
      not authorized.
    - Long-running commands are killed after 30 seconds.

    Do NOT use this for:
    - Reading files — use Read instead (when available).
    - Writing files — use Write instead (when available).
    - Editing files — use Edit instead (when available).
    """

    // `[String: Any]` is intentionally non-Sendable (JSON Schema is heterogeneous).
    // Marked `nonisolated(unsafe)` so the Sendable conformance of `BashTool`
    // remains valid under Swift 6 strict-concurrency. The dictionary is `let`
    // and treated as immutable after init.
    nonisolated(unsafe) let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "Shell command to execute. Supports pipes/redirects/variables."
            ]
        ],
        "required": ["command"]
    ]

    private let runner: ShellRunner

    init(runner: ShellRunner = .shared) {
        self.runner = runner
    }

    private struct Arguments: Decodable {
        let command: String
    }

    func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        let (exit, stdout, stderr) = await runner.runAndCapture(args.command)

        // Compose LLM-facing output. Empty pieces are omitted; sections separated
        // by single newlines.
        var output = stdout
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += "STDERR:\n\(stderr)"
        }
        if exit != 0 {
            if !output.isEmpty { output += "\n" }
            output += "[exit code: \(exit)]"
        }

        // Truncate per context.maxOutputBytes (head + tail preserved).
        // Walks back to a UTF-8 sequence boundary so multibyte characters
        // (CJK, emoji) are never split.
        if context.maxOutputBytes > 0,
           let outputData = output.data(using: .utf8),
           outputData.count > context.maxOutputBytes {
            let keep = context.maxOutputBytes / 2
            let prefixBytes = Self.utf8SafePrefix(outputData, length: keep)
            let suffixBytes = Self.utf8SafeSuffix(outputData, length: keep)
            let prefix = String(data: prefixBytes, encoding: .utf8) ?? ""
            let suffix = String(data: suffixBytes, encoding: .utf8) ?? ""
            output = "\(prefix)\n... [output truncated] ...\n\(suffix)"
        }

        return output.isEmpty ? "(no output)" : output
    }

    /// Returns the longest prefix of `data` no longer than `length` bytes that
    /// ends on a UTF-8 character boundary. Walks back at most 3 bytes (the
    /// maximum UTF-8 continuation-byte run).
    private static func utf8SafePrefix(_ data: Data, length: Int) -> Data {
        guard length < data.count else { return data }
        var end = length
        // UTF-8 continuation bytes start with 0b10xxxxxx (range 0x80..<0xC0).
        // Walk back while the byte AT `end` is a continuation byte — meaning
        // `end` lands mid-sequence — until we find a leading byte boundary.
        while end > 0, end < data.count, (data[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return data.prefix(end)
    }

    /// Returns the longest suffix of `data` no longer than `length` bytes that
    /// starts on a UTF-8 character boundary. Walks forward at most 3 bytes.
    private static func utf8SafeSuffix(_ data: Data, length: Int) -> Data {
        guard length < data.count else { return data }
        var start = data.count - length
        while start < data.count, (data[start] & 0xC0) == 0x80 {
            start += 1
        }
        return data.suffix(from: start)
    }
}

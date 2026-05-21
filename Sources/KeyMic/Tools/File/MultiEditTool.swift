import Foundation

/// A tool for applying multiple edit operations to a file in a single
/// transaction. All edits succeed or none are applied; the file is only
/// written after every edit validates and applies in memory.
///
/// Edits are applied in order; an earlier edit may change the text a later
/// edit matches against. If any edit's `old_string` is empty, identical to
/// its `new_string`, or not found in the working content, the whole
/// operation aborts before writing.
public struct MultiEditTool: Tool {
    public let name = "MultiEdit"

    public let description = """
    Apply multiple edit operations to a file in a single atomic transaction.

    Usage:
    - You MUST use the Read tool first before using this tool
    - All edits succeed or none are applied (transactional). If any edit fails validation, the file is left unchanged
    - Edits are applied in order; earlier edits may change the text that later edits match against
    - Provide edits as a JSON array of objects with "old_string" and "new_string" string keys
    - Each edit performs an exact string replacement (same rules as Edit tool, but each edit may match multiple occurrences)
    - If any edit's old_string is not found, the whole batch aborts and the file is unchanged
    - Use this tool instead of multiple sequential Edit calls when you need to make several changes to the same file
    - Maximum file size: 1MB, UTF-8 text files only
    """

    nonisolated(unsafe) public let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "File path to modify"
            ],
            "edits": [
                "type": "array",
                "description": "Array of {old_string, new_string} edit objects, applied in order",
                "items": [
                    "type": "object",
                    "properties": [
                        "old_string": ["type": "string", "description": "Exact text to find"],
                        "new_string": ["type": "string", "description": "Replacement text"]
                    ],
                    "required": ["old_string", "new_string"]
                ]
            ]
        ],
        "required": ["file_path", "edits"]
    ]

    public init() {}

    private struct Edit: Decodable {
        let oldString: String
        let newString: String

        enum CodingKeys: String, CodingKey {
            case oldString = "old_string"
            case newString = "new_string"
        }
    }

    private struct Arguments: Decodable {
        let filePath: String
        let edits: [Edit]

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case edits
        }
    }

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)

        // Pre-validate every edit before we touch the file at all.
        for (index, edit) in args.edits.enumerated() {
            guard !edit.oldString.isEmpty else {
                throw FileSystemError.operationFailed(reason: "Edit #\(index + 1): 'old_string' cannot be empty")
            }
            guard edit.oldString != edit.newString else {
                throw FileSystemError.operationFailed(reason: "Edit #\(index + 1): 'old_string' and 'new_string' are identical")
            }
        }

        let fs = FileSystemActor(workingDirectory: context.workingDirectory)
        let normalizedPath = await fs.normalizePath(args.filePath)
        guard await fs.isPathSafe(normalizedPath) else {
            throw FileSystemError.pathNotSafe(path: args.filePath)
        }
        var isDirectory: ObjCBool = false
        guard await fs.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) else {
            throw FileSystemError.fileNotFound(path: normalizedPath)
        }
        guard !isDirectory.boolValue else {
            throw FileSystemError.notAFile(path: normalizedPath)
        }

        let originalContent = try await fs.readFile(atPath: normalizedPath)

        // Apply edits in memory. Track per-edit replacement counts so we can
        // surface a summary to the LLM. A zero-match edit aborts the whole
        // batch (Claude-Code semantic: if the caller specified old_string,
        // they meant to find it).
        var workingContent = originalContent
        var summary: [String] = []
        var totalReplacements = 0
        for (index, edit) in args.edits.enumerated() {
            let occurrences = workingContent.components(separatedBy: edit.oldString).count - 1
            guard occurrences > 0 else {
                throw FileSystemError.operationFailed(
                    reason: "Edit #\(index + 1): 'old_string' not found in file (no edits have been applied — all-or-nothing)"
                )
            }
            workingContent = workingContent.replacingOccurrences(
                of: edit.oldString, with: edit.newString
            )
            summary.append("Edit #\(index + 1): replaced \(occurrences) occurrence\(occurrences == 1 ? "" : "s")")
            totalReplacements += occurrences
        }

        // Disk write — at this point every edit produced at least one match,
        // so totalReplacements > 0 by construction. Keep the write
        // unconditional (no special-case empty path).
        try await fs.writeFile(content: workingContent, toPath: normalizedPath)

        return """
        MultiEdit Operation [Success]
        Path: \(normalizedPath)
        \(args.edits.count) edit\(args.edits.count == 1 ? "" : "s") applied, \(totalReplacements) total replacement\(totalReplacements == 1 ? "" : "s")

        \(summary.joined(separator: "\n"))
        """
    }
}

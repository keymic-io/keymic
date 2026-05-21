import Foundation

/// A tool for applying multiple edit operations to a file in a single
/// transaction. All edits succeed or none are applied; the file is only
/// written after every edit validates and applies in memory.
///
/// Edits are applied in order; an earlier edit may change the text a later
/// edit matches against. If any edit's `old` is empty or identical to its
/// `new`, the whole operation aborts before writing.
public struct MultiEditTool: Tool {
    public let name = "MultiEdit"

    public let description = """
    Apply multiple edit operations to a file in a single atomic transaction.

    Usage:
    - You MUST use the Read tool first before using this tool
    - All edits succeed or none are applied (transactional). If any edit fails validation, the file is left unchanged
    - Edits are applied in order; earlier edits may change the text that later edits match against
    - Provide edits as a JSON array of objects with "old" and "new" string keys
    - Each edit performs an exact string replacement (same rules as Edit tool, but each edit may match multiple occurrences)
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
                "description": "Array of {old, new} edit objects, applied in order",
                "items": [
                    "type": "object",
                    "properties": [
                        "old": ["type": "string", "description": "Exact text to find"],
                        "new": ["type": "string", "description": "Replacement text"]
                    ],
                    "required": ["old", "new"]
                ]
            ]
        ],
        "required": ["file_path", "edits"]
    ]

    public init() {}

    private struct Edit: Decodable {
        let old: String
        let new: String
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
            guard !edit.old.isEmpty else {
                throw FileSystemError.operationFailed(reason: "Edit #\(index + 1): 'old' cannot be empty")
            }
            guard edit.old != edit.new else {
                throw FileSystemError.operationFailed(reason: "Edit #\(index + 1): 'old' and 'new' are identical")
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
        // surface a summary to the LLM.
        var workingContent = originalContent
        var summary: [String] = []
        var totalReplacements = 0
        for (index, edit) in args.edits.enumerated() {
            let occurrences = workingContent.components(separatedBy: edit.old).count - 1
            if occurrences > 0 {
                workingContent = workingContent.replacingOccurrences(of: edit.old, with: edit.new)
                summary.append("Edit #\(index + 1): replaced \(occurrences) occurrence\(occurrences == 1 ? "" : "s")")
                totalReplacements += occurrences
            } else {
                summary.append("Edit #\(index + 1): no occurrences of 'old' found (skipped)")
            }
        }

        // Only commit to disk if at least one edit changed something.
        if totalReplacements > 0 {
            try await fs.writeFile(content: workingContent, toPath: normalizedPath)
        }

        let status = totalReplacements > 0 ? "Success" : "No changes"
        return """
        MultiEdit Operation [\(status)]
        Path: \(normalizedPath)
        \(args.edits.count) edit\(args.edits.count == 1 ? "" : "s") attempted, \(totalReplacements) total replacement\(totalReplacements == 1 ? "" : "s")

        \(summary.joined(separator: "\n"))
        """
    }
}

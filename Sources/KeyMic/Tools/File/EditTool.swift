import Foundation

/// A tool for performing exact string replacements in files.
///
/// Default mode requires `old_string` to occur exactly once (refuses to
/// guess which occurrence to change). Set `replace_all: true` to substitute
/// every occurrence.
public struct EditTool: Tool {
    public let name = "Edit"

    public let description = """
    Performs exact string replacements in files.

    Usage:
    - You MUST use the Read tool at least once before editing a file. This tool will not check for that, but the LLM should
    - When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces). Never include line number prefixes in old_string or new_string
    - ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required
    - The edit will FAIL if old_string is not unique in the file. Either provide a larger string with more surrounding context to make it unique, or use replace_all=true to change every instance
    - Use replace_all for replacing and renaming strings across the file
    - old_string and new_string must be different
    - NEVER use the Bash tool with sed or awk to edit files. ALWAYS use this tool instead
    - Maximum file size: 1MB, UTF-8 text files only
    """

    nonisolated(unsafe) public let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "File path to modify"
            ],
            "old_string": [
                "type": "string",
                "description": "Exact text to find"
            ],
            "new_string": [
                "type": "string",
                "description": "Replacement text"
            ],
            "replace_all": [
                "type": "boolean",
                "description": "Replace all occurrences (default: false)"
            ]
        ],
        "required": ["file_path", "old_string", "new_string"]
    ]

    public init() {}

    private struct Arguments: Decodable {
        let filePath: String
        let oldString: String
        let newString: String
        let replaceAll: Bool?

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case oldString = "old_string"
            case newString = "new_string"
            case replaceAll = "replace_all"
        }
    }

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        let replaceAll = args.replaceAll ?? false

        guard !args.oldString.isEmpty else {
            throw FileSystemError.operationFailed(reason: "old_string cannot be empty")
        }
        guard args.oldString != args.newString else {
            throw FileSystemError.operationFailed(reason: "old_string and new_string must be different")
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
        let occurrenceCount = originalContent.components(separatedBy: args.oldString).count - 1

        guard occurrenceCount > 0 else {
            return """
            Edit Operation [Failed]
            Path: \(normalizedPath)
            No occurrences of the specified text were found in the file.
            """
        }

        if !replaceAll && occurrenceCount > 1 {
            return """
            Edit Operation [Failed]
            Path: \(normalizedPath)
            Found \(occurrenceCount) occurrences of old_string. Either provide a larger string with more surrounding context to make the match unique, or use replace_all=true to change every instance.
            """
        }

        let newContent: String
        let replacements: Int
        if replaceAll {
            newContent = originalContent.replacingOccurrences(of: args.oldString, with: args.newString)
            replacements = occurrenceCount
        } else if let range = originalContent.range(of: args.oldString) {
            newContent = originalContent.replacingCharacters(in: range, with: args.newString)
            replacements = 1
        } else {
            // Should not happen — occurrenceCount > 0 implies range exists.
            throw FileSystemError.operationFailed(reason: "internal: occurrence count > 0 but range lookup failed")
        }

        try await fs.writeFile(content: newContent, toPath: normalizedPath)

        let oldPreview = String(args.oldString.prefix(100)) + (args.oldString.count > 100 ? "..." : "")
        let newPreview = String(args.newString.prefix(100)) + (args.newString.count > 100 ? "..." : "")

        return """
        Edit Operation [Success]
        Path: \(normalizedPath)
        Replaced \(replacements) occurrence\(replacements == 1 ? "" : "s")
        - Old: "\(oldPreview)"
        + New: "\(newPreview)"
        """
    }
}

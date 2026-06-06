import Foundation

/// A tool for writing content to files. Creates parent directories if
/// missing, writes atomically, and refuses paths outside
/// `context.workingDirectory`.
public struct WriteTool: Tool {
    public let name = "Write"

    public let description = """
    Writes a file to the local filesystem.

    Usage:
    - This tool will overwrite the existing file if there is one at the provided path
    - If this is an existing file, you MUST use the Read tool first to read the file's contents
    - Creates parent directories automatically if they don't exist
    - ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required
    - NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested
    - NEVER use the Bash tool with echo or cat heredoc to write files. ALWAYS use this tool instead
    - Maximum content size: 1MB, UTF-8 encoding only
    """

    nonisolated(unsafe) public let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "File path to write to (absolute, relative to working directory, or ~/)"
            ],
            "content": [
                "type": "string",
                "description": "Content to write"
            ]
        ],
        "required": ["file_path", "content"]
    ]

    public init() {}

    private struct Arguments: Decodable {
        let filePath: String
        let content: String

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case content
        }
    }

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        let fs = FileSystemActor(workingDirectory: context.workingDirectory)

        let normalizedPath = await fs.normalizePath(args.filePath)
        guard await fs.isPathSafe(normalizedPath) else {
            throw FileSystemError.pathNotSafe(path: args.filePath)
        }

        var isDirectory: ObjCBool = false
        let existed = await fs.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)
        if existed {
            guard !isDirectory.boolValue else {
                throw FileSystemError.notAFile(path: normalizedPath)
            }
        }

        try await fs.writeFile(content: args.content, toPath: normalizedPath)

        let bytesWritten = args.content.data(using: .utf8)?.count ?? 0
        let action = existed ? "overwritten" : "created"
        return """
        Write Operation [Success]
        Path: \(normalizedPath)
        Bytes written: \(bytesWritten)
        File \(action) successfully
        """
    }
}

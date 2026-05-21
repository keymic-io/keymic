import Foundation

/// A tool for reading file contents from the local filesystem.
///
/// Reads a file with optional line offset/limit, formats output with line
/// numbers (1-based), and truncates long lines. Path resolution is
/// constrained to `context.workingDirectory` for safety.
public struct ReadTool: Tool {
    public let name = "Read"

    public let description = """
    Reads a file from the local filesystem. You can access any file directly by using this tool.
    Assume this tool is able to read all files on the machine. If the user provides a path to a file assume that path is valid. It is okay to read a file that does not exist; an error will be returned.

    Usage:
    - The file_path parameter supports absolute paths, paths relative to the working directory, or paths starting with ~/
    - By default, it reads up to 2000 lines starting from the beginning of the file
    - You can optionally specify a line offset and limit (especially handy for long files), but it's recommended to read the whole file by not providing these parameters
    - Any lines longer than 2000 characters will be truncated
    - Results are returned with line numbers starting at 1 (e.g., "1→content")
    - This tool can only read files, not directories. To read a directory, use an ls command via the Bash tool
    - You can call multiple tools in a single response. It is always better to speculatively read multiple potentially useful files in parallel
    - If you read a file that exists but has empty contents you will receive an empty string
    - NEVER use the Bash tool with cat, head, or tail to read files. ALWAYS use this tool instead
    - Maximum file size: 1MB, UTF-8 text files only
    """

    nonisolated(unsafe) public let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "File path (absolute, relative to working directory, or starting with ~/)"
            ],
            "offset": [
                "type": "integer",
                "description": "Line offset to start from (0-based, default: 0)"
            ],
            "limit": [
                "type": "integer",
                "description": "Number of lines to read (default: 2000)"
            ]
        ],
        "required": ["file_path"]
    ]

    public init() {}

    private struct Arguments: Decodable {
        let file_path: String
        let offset: Int?
        let limit: Int?
    }

    private static let defaultLineLimit = 2000
    private static let maxLineLength = 2000

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        let fs = FileSystemActor(workingDirectory: context.workingDirectory)

        let normalizedPath = await fs.normalizePath(args.file_path)
        guard await fs.isPathSafe(normalizedPath) else {
            throw FileSystemError.pathNotSafe(path: args.file_path)
        }

        guard await fs.fileExists(atPath: normalizedPath) else {
            throw FileSystemError.fileNotFound(path: normalizedPath)
        }

        var isDirectory: ObjCBool = false
        _ = await fs.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw FileSystemError.notAFile(path: normalizedPath)
        }

        let content = try await fs.readFile(atPath: normalizedPath)
        let lines = content.components(separatedBy: .newlines)
        let totalLines = lines.count

        let offset = max(0, args.offset ?? 0)
        let limitValue = args.limit ?? 0
        let limit = limitValue > 0 ? limitValue : Self.defaultLineLimit

        let startLine = offset + 1
        let endLine = min(offset + limit, totalLines)

        guard startLine <= totalLines else {
            return """
            Read Operation [Success]
            Path: \(normalizedPath)
            Lines: 0 of \(totalLines) (offset past end of file)
            """
        }

        var formattedLines: [String] = []
        var truncatedLines = 0
        for lineNum in startLine...endLine {
            let lineIndex = lineNum - 1
            guard lineIndex < lines.count else { continue }
            var line = lines[lineIndex]
            if line.count > Self.maxLineLength {
                line = String(line.prefix(Self.maxLineLength)) + "..."
                truncatedLines += 1
            }
            formattedLines.append("\(lineNum)→\(line)")
        }

        let formattedContent = formattedLines.joined(separator: "\n")
        let truncateNote = truncatedLines > 0 ? " (\(truncatedLines) lines truncated)" : ""

        return """
        Read Operation [Success]
        Path: \(normalizedPath)
        Lines: \(startLine)-\(endLine) of \(totalLines) (\(formattedLines.count) lines read)\(truncateNote)

        \(formattedContent)
        """
    }
}

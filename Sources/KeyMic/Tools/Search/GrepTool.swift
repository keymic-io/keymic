import Foundation

public struct GrepTool: Tool {
    public let name = "Grep"

    public let description = "Searches file contents by regex within the working directory sandbox, with optional glob filtering, content/count output, context lines, and pagination."

    nonisolated(unsafe) public let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "Regular expression pattern to search for."
            ],
            "path": [
                "type": "string",
                "description": "Optional base file or directory to search from. Defaults to the tool working directory."
            ],
            "glob": [
                "type": "string",
                "description": "Optional glob used to filter files when searching a directory. Defaults to **/*."
            ],
            "output_mode": [
                "type": "string",
                "description": "Output format: files_with_matches (default), content, or count."
            ],
            "case_sensitive": [
                "type": "boolean",
                "description": "Whether regex matching is case-sensitive. Defaults to true."
            ],
            "multiline": [
                "type": "boolean",
                "description": "Whether to search the whole file and allow cross-line matches. Defaults to false."
            ],
            "before_context": [
                "type": "integer",
                "description": "Number of context lines to show before each content match."
            ],
            "after_context": [
                "type": "integer",
                "description": "Number of context lines to show after each content match."
            ],
            "context": [
                "type": "integer",
                "description": "Default number of context lines to show before and after matches."
            ],
            "show_line_numbers": [
                "type": "boolean",
                "description": "Whether content output includes 1-based line numbers. Defaults to true."
            ],
            "head_limit": [
                "type": "integer",
                "description": "Maximum number of output entries to return. 0 means unlimited."
            ],
            "offset": [
                "type": "integer",
                "description": "Number of output entries to skip before returning results."
            ]
        ],
        "required": ["pattern"]
    ]

    public init() {}

    private struct Arguments: Decodable {
        let pattern: String
        let path: String?
        let glob: String?
        let outputMode: String?
        let caseSensitive: Bool?
        let multiline: Bool?
        let beforeContext: Int?
        let afterContext: Int?
        let context: Int?
        let showLineNumbers: Bool?
        let headLimit: Int?
        let offset: Int?

        enum CodingKeys: String, CodingKey {
            case pattern
            case path
            case glob
            case outputMode = "output_mode"
            case caseSensitive = "case_sensitive"
            case multiline
            case beforeContext = "before_context"
            case afterContext = "after_context"
            case context
            case showLineNumbers = "show_line_numbers"
            case headLimit = "head_limit"
            case offset
        }
    }

    private enum OutputMode {
        case filesWithMatches
        case content
        case count
    }

    private struct SearchFile {
        let absolutePath: String
        let relativePath: String
    }

    private struct ContentBlock {
        let relativePath: String
        let body: String
    }

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        let fs = FileSystemActor(workingDirectory: context.workingDirectory)

        let basePath: String
        if let path = args.path {
            basePath = await fs.normalizePath(path)
        } else {
            basePath = await fs.normalizePath(context.workingDirectory)
        }

        guard await fs.isPathSafe(basePath) else {
            throw FileSystemError.pathNotSafe(path: args.path ?? basePath)
        }
        guard await fs.fileExists(atPath: basePath) else {
            throw FileSystemError.fileNotFound(path: basePath)
        }

        let outputMode = try parseOutputMode(args.outputMode)
        let showLineNumbers = args.showLineNumbers ?? true
        let sharedContext = max(0, args.context ?? 0)
        let beforeContext = args.beforeContext.map { max(0, $0) } ?? sharedContext
        let afterContext = args.afterContext.map { max(0, $0) } ?? sharedContext
        let limit = max(0, args.headLimit ?? 0)
        let offset = max(0, args.offset ?? 0)

        var regexOptions: NSRegularExpression.Options = (args.caseSensitive ?? true) ? [] : [.caseInsensitive]
        if args.multiline ?? false {
            regexOptions.insert(.dotMatchesLineSeparators)
        }
        let regex = try NSRegularExpression(pattern: args.pattern, options: regexOptions)

        var baseIsDirectory = ObjCBool(false)
        let exists = await fs.fileExists(atPath: basePath, isDirectory: &baseIsDirectory)
        guard exists else {
            throw FileSystemError.fileNotFound(path: basePath)
        }

        let files: [SearchFile]
        if baseIsDirectory.boolValue {
            files = try await enumerateFiles(
                under: basePath,
                glob: args.glob ?? "**/*",
                fs: fs,
                context: context
            )
        } else {
            let relativePath = URL(fileURLWithPath: basePath).lastPathComponent
            files = [SearchFile(absolutePath: basePath, relativePath: relativePath)]
        }

        var filesWithMatches: [String] = []
        var countsByFile: [(String, Int)] = []
        var contentBlocks: [ContentBlock] = []
        var readErrors: [String] = []

        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            if context.isCancelled() { throw CancellationError() }

            do {
                guard await fs.isPathSafe(file.absolutePath) else { continue }
                let content = try await fs.readFile(atPath: file.absolutePath)
                if args.multiline ?? false {
                    let fileMatchCount = regex.numberOfMatches(
                        in: content,
                        options: [],
                        range: fullRange(of: content)
                    )
                    guard fileMatchCount > 0 else { continue }
                    filesWithMatches.append(file.relativePath)
                    countsByFile.append((file.relativePath, fileMatchCount))
                    if outputMode == .content {
                        let block = buildMultilineContentBlock(
                            relativePath: file.relativePath,
                            content: content,
                            regex: regex,
                            beforeContext: beforeContext,
                            afterContext: afterContext,
                            showLineNumbers: showLineNumbers
                        )
                        if let block { contentBlocks.append(block) }
                    }
                } else {
                    let lineMatches = buildLineMatches(
                        relativePath: file.relativePath,
                        content: content,
                        regex: regex,
                        beforeContext: beforeContext,
                        afterContext: afterContext,
                        showLineNumbers: showLineNumbers,
                        includeContent: outputMode == .content
                    )
                    guard lineMatches.matchCount > 0 else { continue }
                    filesWithMatches.append(file.relativePath)
                    countsByFile.append((file.relativePath, lineMatches.matchCount))
                    if let block = lineMatches.contentBlock {
                        contentBlocks.append(block)
                    }
                }
            } catch {
                readErrors.append("\(file.relativePath): \(describeReadError(error, path: file.absolutePath))")
            }
        }

        let entries: [String]
        switch outputMode {
        case .filesWithMatches:
            entries = paginate(filesWithMatches.sorted(), offset: offset, limit: limit)
        case .count:
            let lines = countsByFile
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0): \($0.1)" }
            entries = paginate(lines, offset: offset, limit: limit)
        case .content:
            let blocks = contentBlocks
                .sorted { $0.relativePath < $1.relativePath }
                .map { block in
                    block.body.isEmpty ? block.relativePath : "\(block.relativePath)\n\(block.body)"
                }
            entries = paginate(blocks, offset: offset, limit: limit)
        }

        let totalMatches: Int
        switch outputMode {
        case .filesWithMatches, .count:
            totalMatches = filesWithMatches.count
        case .content:
            totalMatches = contentBlocks.count
        }

        var lines = [
            "Grep Operation [Success]",
            "Pattern: \(args.pattern)",
            "Base: \(basePath)",
            "Found \(totalMatches) match(es)"
        ]

        if entries.isEmpty {
            lines.append("No matches found")
        } else {
            lines.append(contentsOf: entries)
        }

        if !readErrors.isEmpty {
            lines.append("Read errors (\(readErrors.count)): \(readErrors.sorted().joined(separator: "; "))")
        }

        return Self.truncateIfNeeded(lines.joined(separator: "\n"), maxBytes: context.maxOutputBytes)
    }

    private func parseOutputMode(_ value: String?) throws -> OutputMode {
        switch (value ?? "files_with_matches").lowercased() {
        case "files_with_matches", "default":
            return .filesWithMatches
        case "content":
            return .content
        case "count":
            return .count
        default:
            throw FileSystemError.operationFailed(reason: "Unsupported output_mode: \(value ?? "")")
        }
    }

    private func enumerateFiles(
        under basePath: String,
        glob: String,
        fs: FileSystemActor,
        context: ToolContext
    ) async throws -> [SearchFile] {
        let baseURL = URL(fileURLWithPath: basePath)
        let regex = try NSRegularExpression(
            pattern: "^" + GlobTool.globToRegex(glob) + "$",
            options: []
        )
        let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let resolvedBasePath = baseURL.resolvingSymlinksInPath().standardized.path
        let baseWithSlash = resolvedBasePath.hasSuffix("/") ? resolvedBasePath : resolvedBasePath + "/"

        var files: [SearchFile] = []
        while let next = enumerator?.nextObject() as? URL {
            if context.isCancelled() { throw CancellationError() }

            let absolutePath = next.path
            guard await fs.isPathSafe(absolutePath) else { continue }

            let resolvedAbsolutePath = next.resolvingSymlinksInPath().standardized.path
            guard resolvedAbsolutePath.hasPrefix(baseWithSlash) else { continue }
            guard await fs.isPathSafe(resolvedAbsolutePath) else { continue }

            let relativePath = String(resolvedAbsolutePath.dropFirst(baseWithSlash.count))
            if relativePath.isEmpty || containsHiddenComponent(relativePath) { continue }

            let resolvedURL = URL(fileURLWithPath: resolvedAbsolutePath)
            let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true || values.isRegularFile != true { continue }

            let range = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
            guard regex.firstMatch(in: relativePath, options: [], range: range) != nil else { continue }
            files.append(SearchFile(absolutePath: resolvedAbsolutePath, relativePath: relativePath))
        }

        return files
    }

    private func buildLineMatches(
        relativePath: String,
        content: String,
        regex: NSRegularExpression,
        beforeContext: Int,
        afterContext: Int,
        showLineNumbers: Bool,
        includeContent: Bool
    ) -> (matchCount: Int, contentBlock: ContentBlock?) {
        let lines = content.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var matchingIndices = Set<Int>()

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                matchingIndices.insert(index)
            }
        }

        let matchCount = matchingIndices.count
        guard includeContent, matchCount > 0 else {
            return (matchCount, nil)
        }

        var includedIndices = Set<Int>()
        for matchIndex in matchingIndices {
            let start = max(0, matchIndex - beforeContext)
            let end = min(lines.count - 1, matchIndex + afterContext)
            for index in start...end {
                includedIndices.insert(index)
            }
        }

        let rendered = includedIndices.sorted().map { index -> String in
            let line = lines[index]
            let prefix: String
            if showLineNumbers {
                prefix = matchingIndices.contains(index) ? "\(index + 1)→" : "\(index + 1): "
            } else {
                prefix = ""
            }
            return prefix + line
        }.joined(separator: "\n")

        return (matchCount, ContentBlock(relativePath: relativePath, body: rendered))
    }

    private func buildMultilineContentBlock(
        relativePath: String,
        content: String,
        regex: NSRegularExpression,
        beforeContext: Int,
        afterContext: Int,
        showLineNumbers: Bool
    ) -> ContentBlock? {
        let matches = regex.matches(in: content, options: [], range: fullRange(of: content))
        guard !matches.isEmpty else { return nil }

        let snippets = matches.compactMap { match -> String? in
            guard let range = Range(match.range, in: content) else { return nil }
            let snippet = String(content[range])
            guard !snippet.isEmpty else { return nil }

            if beforeContext == 0, afterContext == 0 {
                guard showLineNumbers else { return snippet }
                let startLine = lineNumber(forUTF16Location: match.range.location, in: content)
                let snippetLines = snippet.components(separatedBy: .newlines)
                return snippetLines.enumerated().map { offset, line in
                    let lineNumber = startLine + offset
                    let prefix = offset == 0 ? "\(lineNumber)→" : "\(lineNumber): "
                    return prefix + line
                }.joined(separator: "\n")
            }

            return renderMultilineContext(
                content: content,
                matchRange: match.range,
                beforeContext: beforeContext,
                afterContext: afterContext,
                showLineNumbers: showLineNumbers
            )
        }

        guard !snippets.isEmpty else { return nil }
        return ContentBlock(relativePath: relativePath, body: snippets.joined(separator: "\n---\n"))
    }

    private struct LineInfo {
        let number: Int
        let text: String
        let range: NSRange
    }

    private func renderMultilineContext(
        content: String,
        matchRange: NSRange,
        beforeContext: Int,
        afterContext: Int,
        showLineNumbers: Bool
    ) -> String {
        let lines = lineInfos(for: content)
        guard !lines.isEmpty else { return "" }
        let matchEnd = max(matchRange.location, matchRange.location + matchRange.length - 1)
        let matchingIndices = lines.indices.filter { index in
            let lineRange = lines[index].range
            return lineRange.location <= matchEnd && NSMaxRange(lineRange) > matchRange.location
        }
        guard let firstMatchIndex = matchingIndices.first,
              let lastMatchIndex = matchingIndices.last else {
            return ""
        }

        let start = max(lines.startIndex, firstMatchIndex - beforeContext)
        let end = min(lines.index(before: lines.endIndex), lastMatchIndex + afterContext)
        let matchingIndexSet = Set(matchingIndices)

        return (start...end).map { index in
            let line = lines[index]
            guard showLineNumbers else { return line.text }
            let prefix = matchingIndexSet.contains(index) ? "\(line.number)→" : "\(line.number): "
            return prefix + line.text
        }.joined(separator: "\n")
    }

    private func lineInfos(for content: String) -> [LineInfo] {
        let nsString = content as NSString
        var infos: [LineInfo] = []
        var location = 0
        var lineNumber = 1

        while location < nsString.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsString.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))

            let contentRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            infos.append(LineInfo(
                number: lineNumber,
                text: nsString.substring(with: contentRange),
                range: contentRange
            ))

            location = lineEnd
            lineNumber += 1
        }

        return infos
    }

    private func paginate(_ entries: [String], offset: Int, limit: Int) -> [String] {
        guard offset < entries.count else { return [] }
        let dropped = Array(entries.dropFirst(offset))
        guard limit > 0 else { return dropped }
        return Array(dropped.prefix(limit))
    }

    private func describeReadError(_ error: Error, path: String) -> String {
        if let fsError = error as? FileSystemError,
           let description = fsError.errorDescription {
            return description
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return FileSystemError.permissionDenied(path: path).errorDescription ?? nsError.localizedDescription
        }
        return nsError.localizedDescription
    }

    private func lineNumber(forUTF16Location location: Int, in content: String) -> Int {
        let utf16 = content.utf16
        let safeLocation = max(0, min(location, utf16.count))
        let index = String.UTF16View.Index(utf16Offset: safeLocation, in: content)
        let prefix = content[..<index]
        return prefix.reduce(into: 1) { partialResult, character in
            if character == "\n" { partialResult += 1 }
        }
    }

    private func fullRange(of string: String) -> NSRange {
        NSRange(string.startIndex..<string.endIndex, in: string)
    }

    private func containsHiddenComponent(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    private static func truncateIfNeeded(_ output: String, maxBytes: Int) -> String {
        guard maxBytes > 0, let data = output.data(using: .utf8), data.count > maxBytes else {
            return output
        }

        let marker = "\n[output truncated]\n"
        let markerData = marker.data(using: .utf8)!
        guard maxBytes > markerData.count else {
            return String(data: utf8SafePrefix(markerData, length: maxBytes), encoding: .utf8) ?? ""
        }

        let remaining = maxBytes - markerData.count
        let prefixLength = remaining / 2
        let suffixLength = remaining - prefixLength
        let prefixBytes = utf8SafePrefix(data, length: prefixLength)
        let suffixBytes = utf8SafeSuffix(data, length: suffixLength)
        let prefix = String(data: prefixBytes, encoding: .utf8) ?? ""
        let suffix = String(data: suffixBytes, encoding: .utf8) ?? ""
        let truncated = prefix + marker + suffix

        guard let truncatedData = truncated.data(using: .utf8), truncatedData.count > maxBytes else {
            return truncated
        }
        return String(data: utf8SafePrefix(truncatedData, length: maxBytes), encoding: .utf8) ?? ""
    }

    private static func utf8SafePrefix(_ data: Data, length: Int) -> Data {
        guard length < data.count else { return data }
        var end = length
        while end > 0, end < data.count, (data[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return data.prefix(end)
    }

    private static func utf8SafeSuffix(_ data: Data, length: Int) -> Data {
        guard length < data.count else { return data }
        var start = data.count - length
        while start < data.count, (data[start] & 0xC0) == 0x80 {
            start += 1
        }
        return data.suffix(from: start)
    }
}

import Foundation

public struct GlobTool: Tool {
    public let name = "Glob"

    public let description = "Finds files and directories by shell-style glob pattern within the working directory sandbox."

    nonisolated(unsafe) public let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "Shell-style glob pattern to match against relative paths."
            ],
            "path": [
                "type": "string",
                "description": "Optional base directory to search from. Defaults to the tool working directory."
            ],
            "file_type": [
                "type": "string",
                "description": "Filter matches by type: file (default), dir/directory, or any/all."
            ],
            "case_sensitive": [
                "type": "boolean",
                "description": "Whether matching should be case-sensitive. Defaults to true."
            ]
        ],
        "required": ["pattern"]
    ]

    public init() {}

    private struct Arguments: Decodable {
        let pattern: String
        let path: String?
        let fileType: String?
        let caseSensitive: Bool?

        enum CodingKeys: String, CodingKey {
            case pattern
            case path
            case fileType = "file_type"
            case caseSensitive = "case_sensitive"
        }
    }

    private enum MatchType {
        case file
        case directory
        case any
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

        var baseIsDirectory: ObjCBool = false
        _ = await fs.fileExists(atPath: basePath, isDirectory: &baseIsDirectory)
        guard baseIsDirectory.boolValue else {
            throw FileSystemError.notADirectory(path: basePath)
        }

        let matchType = try parseMatchType(args.fileType)
        let regex = try Self.makeRegex(pattern: args.pattern, caseSensitive: args.caseSensitive ?? true)
        let recursive = args.pattern.contains("**")
        let baseURL = URL(fileURLWithPath: basePath)

        var matches: [String] = []
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let resolvedBasePath = URL(fileURLWithPath: basePath).resolvingSymlinksInPath().standardized.path
            let baseWithSlash = resolvedBasePath.hasSuffix("/") ? resolvedBasePath : resolvedBasePath + "/"

            while let next = enumerator?.nextObject() as? URL {
                if context.isCancelled() { throw CancellationError() }
                let absolutePath = next.path
                let resolvedAbsolutePath = next.resolvingSymlinksInPath().standardized.path
                guard resolvedAbsolutePath.hasPrefix(baseWithSlash) else { continue }
                let relativePath = String(resolvedAbsolutePath.dropFirst(baseWithSlash.count))
                if relativePath.isEmpty || containsHiddenComponent(relativePath) { continue }
                guard await fs.isPathSafe(absolutePath) else { continue }
                if try shouldInclude(url: next, relativePath: relativePath, regex: regex, matchType: matchType) {
                    matches.append(relativePath)
                }
            }
        } else {
            for entry in try await fs.listDirectory(atPath: basePath).sorted() {
                if context.isCancelled() { throw CancellationError() }
                if entry.hasPrefix(".") { continue }
                let absolutePath = baseURL.appendingPathComponent(entry).path
                guard await fs.isPathSafe(absolutePath) else { continue }
                let url = URL(fileURLWithPath: absolutePath)
                if try shouldInclude(url: url, relativePath: entry, regex: regex, matchType: matchType) {
                    matches.append(entry)
                }
            }
        }

        matches.sort()
        var output = [
            "Glob Operation [Success]",
            "Pattern: \(args.pattern)",
            "Base: \(basePath)",
            "Found \(matches.count) match(es)"
        ]
        if matches.isEmpty {
            output.append("No matches found")
        } else {
            output.append(contentsOf: matches)
        }

        return Self.truncateIfNeeded(output.joined(separator: "\n"), maxBytes: context.maxOutputBytes)
    }

    private func parseMatchType(_ value: String?) throws -> MatchType {
        switch (value ?? "file").lowercased() {
        case "file":
            return .file
        case "dir", "directory":
            return .directory
        case "any", "all":
            return .any
        default:
            throw FileSystemError.operationFailed(reason: "Unsupported file_type: \(value ?? "")")
        }
    }

    private func shouldInclude(
        url: URL,
        relativePath: String,
        regex: NSRegularExpression,
        matchType: MatchType
    ) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory ?? false
        switch matchType {
        case .file where isDirectory:
            return false
        case .directory where !isDirectory:
            return false
        default:
            break
        }

        let range = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
        return regex.firstMatch(in: relativePath, options: [], range: range) != nil
    }

    private static func makeRegex(pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
        let regexPattern = "^" + globToRegex(pattern) + "$"
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        return try NSRegularExpression(pattern: regexPattern, options: options)
    }

    private static func globToRegex(_ pattern: String) -> String {
        let chars = Array(pattern)
        var i = 0
        var out = ""

        while i < chars.count {
            let char = chars[i]
            if char == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                    } else {
                        out += ".*"
                        i += 2
                    }
                } else {
                    out += "[^/]*"
                    i += 1
                }
                continue
            }

            if char == "?" {
                out += "[^/]"
                i += 1
                continue
            }

            if char == "[" {
                var j = i + 1
                var classBody = ""
                if j < chars.count, chars[j] == "!" {
                    classBody += "^"
                    j += 1
                } else if j < chars.count, chars[j] == "^" {
                    classBody += "\\^"
                    j += 1
                }

                while j < chars.count, chars[j] != "]" {
                    let member = chars[j]
                    if "\\".contains(member) {
                        classBody += "\\\\"
                    } else {
                        classBody.append(member)
                    }
                    j += 1
                }

                if j < chars.count, chars[j] == "]" {
                    out += "[\(classBody)]"
                    i = j + 1
                    continue
                }
            }

            out += escapeRegexLiteral(char)
            i += 1
        }

        return out
    }

    private static func escapeRegexLiteral(_ character: Character) -> String {
        if "\\.^$|()[]{}+?*".contains(character) {
            return "\\\(character)"
        }
        return String(character)
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

    private func containsHiddenComponent(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

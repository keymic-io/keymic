import CryptoKit
import Foundation
import MCP

public struct MCPToolAdapter: Tool {
    public let serverName: String
    public let remoteName: String
    public let description: String
    public nonisolated(unsafe) let parametersJSONSchema: [String: Any]
    let registrationID = UUID()

    private let client: MCPClientProtocol

    /// OpenAI's `tools[i].function.name` regex is `^[a-zA-Z0-9_-]{1,64}$` —
    /// dots and most other punctuation are rejected with HTTP 400, and so is
    /// any name longer than 64 characters. We also scrub any `.` / whitespace
    /// in `serverName` because users may have configured a server id like
    /// `github.copilot` in their MCP config. An over-length `server_tool`
    /// combination is truncated with a deterministic hash suffix so distinct
    /// long names stay distinct (a single >64 name would otherwise 400 the
    /// whole request and terminate the entire agent run).
    public var name: String {
        Self.capForOpenAI("\(Self.sanitizeForOpenAI(serverName))_\(Self.sanitizeForOpenAI(remoteName))")
    }

    static let maxOpenAINameLength = 64

    private static func sanitizeForOpenAI(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        return out
    }

    /// Truncate a sanitized name to `maxOpenAINameLength`, appending an 8-char
    /// hex suffix derived from the full name so two long names that share a
    /// prefix don't collide. Sanitized characters are all ASCII, so character
    /// count equals byte count and prefixing by character is safe.
    static func capForOpenAI(_ sanitized: String) -> String {
        guard sanitized.count > maxOpenAINameLength else { return sanitized }
        let suffix = stableHash8(sanitized)
        let keep = maxOpenAINameLength - 1 - suffix.count // room for '_' + suffix
        return "\(sanitized.prefix(keep))_\(suffix)"
    }

    /// First 4 bytes of SHA-256 as 8 lowercase hex chars — deterministic across
    /// runs (unlike `Hasher`, which is seeded) so the wire name is stable.
    private static func stableHash8(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public init(
        serverName: String,
        remoteName: String,
        description: String,
        parametersJSONSchema: [String: Any],
        client: MCPClientProtocol
    ) {
        self.serverName = serverName
        self.remoteName = remoteName
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
        self.client = client
    }

    public static func make(
        from descriptor: MCP.Tool,
        serverName: String,
        client: MCPClientProtocol
    ) throws -> MCPToolAdapter {
        MCPToolAdapter(
            serverName: serverName,
            remoteName: descriptor.name,
            description: descriptor.description ?? "",
            parametersJSONSchema: toJSONSchemaDict(descriptor.inputSchema),
            client: client
        )
    }

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        if context.isCancelled() { throw CancellationError() }

        let arguments = try decodeArguments(argumentsJSON)

        if context.isCancelled() { throw CancellationError() }

        let result = try await client.callTool(name: remoteName, arguments: arguments)

        if context.isCancelled() { throw CancellationError() }

        let flattened = flatten(result.content)
        let output = flattened.isEmpty ? "(no output)" : flattened
        let truncatedOutput = truncate(output, maxBytes: context.maxOutputBytes)
        if result.isError {
            throw MCPClientError.toolCallFailed(
                server: serverName,
                tool: remoteName,
                reason: truncatedOutput
            )
        }

        return truncatedOutput
    }

    private func decodeArguments(_ argumentsJSON: Data) throws -> [String: Value]? {
        guard !argumentsJSON.isEmpty else { return nil }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: argumentsJSON, options: [.fragmentsAllowed])
        } catch {
            throw MCPClientError.toolCallFailed(
                server: serverName,
                tool: remoteName,
                reason: "invalid JSON arguments: \(error.localizedDescription)"
            )
        }

        if json is NSNull {
            return nil
        }

        guard let object = json as? [String: Any] else {
            throw MCPClientError.toolCallFailed(
                server: serverName,
                tool: remoteName,
                reason: "arguments must be a JSON object"
            )
        }

        var converted: [String: Value] = [:]
        for (key, value) in object {
            converted[key] = try Self.value(fromJSONObject: value)
        }
        return converted
    }

    private static func value(fromJSONObject json: Any) throws -> Value {
        if json is NSNull {
            return .null
        }

        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }

            let objCType = String(cString: number.objCType)
            switch objCType {
            case "f", "d":
                return .double(number.doubleValue)
            default:
                return .int(number.intValue)
            }
        }

        if let bool = json as? Bool {
            return .bool(bool)
        }

        if let string = json as? String {
            return .string(string)
        }

        if let array = json as? [Any] {
            return .array(try array.map { try value(fromJSONObject: $0) })
        }

        if let object = json as? [String: Any] {
            var converted: [String: Value] = [:]
            for (key, nestedValue) in object {
                converted[key] = try value(fromJSONObject: nestedValue)
            }
            return .object(converted)
        }

        throw MCPClientError.configInvalid(reason: "Unsupported JSON value in MCP tool arguments")
    }

    private static func toJSONSchemaDict(_ schema: Value) -> [String: Any] {
        guard case .object(let object) = schema else {
            return [
                "type": "object",
                "properties": [:]
            ]
        }

        var dict = object.mapValues { unwrapSchemaValue($0) }
        // OpenAI rejects `tools[i].function.parameters` with HTTP 400 unless the
        // top-level shape is `{"type":"object","properties":...}`. MCP servers
        // are allowed to omit `type` (it defaults to "object" under the MCP
        // spec) or to set it to a non-"object" container — both shapes break
        // the entire agent session, not just the offending tool, so we normalize
        // here defensively.
        let typeValue = dict["type"] as? String
        if typeValue != "object" {
            dict["type"] = "object"
        }
        if dict["properties"] == nil {
            dict["properties"] = [String: Any]()
        }
        return dict
    }

    private static func unwrapSchemaValue(_ value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .data(let mimeType, let data):
            let encoded = data.base64EncodedString()
            if let mimeType, !mimeType.isEmpty {
                return "data:\(mimeType);base64,\(encoded)"
            }
            return encoded
        case .array(let array):
            return array.map { unwrapSchemaValue($0) }
        case .object(let object):
            return object.mapValues { unwrapSchemaValue($0) }
        }
    }

    private func flatten(_ content: [MCP.Tool.Content]) -> String {
        content.map { item in
            switch item {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "[image: \(mimeType)]"
            case .audio(_, let mimeType, _, _):
                return "[audio: \(mimeType)]"
            case .resource(let resource, _, _):
                var parts = ["resource: \(resource.uri)"]
                if let mimeType = resource.mimeType, !mimeType.isEmpty {
                    parts.append(mimeType)
                }
                let header = "[\(parts.joined(separator: " "))]"
                if let text = resource.text {
                    return "\(header)\n\(text)"
                }
                if let blob = resource.blob {
                    return "\(header) [blob: \(blob.utf8.count) base64 bytes]"
                }
                return header
            case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
                var parts = ["resourceLink: \(name)", uri]
                if let title, !title.isEmpty {
                    parts.append("title=\(title)")
                }
                if let description, !description.isEmpty {
                    parts.append("description=\(description)")
                }
                if let mimeType, !mimeType.isEmpty {
                    parts.append("mimeType=\(mimeType)")
                }
                return "[\(parts.joined(separator: " "))]"
            }
        }
        .joined(separator: "\n")
    }

    private func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return text }

        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }

        let marker = "\n... [output truncated] ...\n"
        let markerBytes = Array(marker.utf8)
        guard maxBytes > markerBytes.count else {
            return validUTF8Prefix(markerBytes, maxBytes: maxBytes)
        }

        let available = maxBytes - markerBytes.count
        let headBytes = available / 2
        let tailBytes = available - headBytes

        return validUTF8Prefix(bytes, maxBytes: headBytes)
            + marker
            + validUTF8Suffix(bytes, maxBytes: tailBytes)
    }

    private func validUTF8Prefix(_ bytes: [UInt8], maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var length = min(maxBytes, bytes.count)
        while length > 0 {
            if let string = String(bytes: bytes.prefix(length), encoding: .utf8) {
                return string
            }
            length -= 1
        }
        return ""
    }

    private func validUTF8Suffix(_ bytes: [UInt8], maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var start = max(0, bytes.count - maxBytes)
        while start < bytes.count {
            if let string = String(bytes: bytes[start...], encoding: .utf8) {
                return string
            }
            start += 1
        }
        return ""
    }
}

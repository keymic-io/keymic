import Foundation
import MCP

public struct MCPToolAdapter: Tool {
    public let serverName: String
    public let remoteName: String
    public let description: String
    public nonisolated(unsafe) let parametersJSONSchema: [String: Any]

    private let client: MCPClientProtocol

    public var name: String {
        "\(serverName).\(remoteName)"
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
        if result.isError {
            throw MCPClientError.toolCallFailed(
                server: serverName,
                tool: remoteName,
                reason: flattened.isEmpty ? "(no output)" : flattened
            )
        }

        let output = flattened.isEmpty ? "(no output)" : flattened
        return truncate(output, maxBytes: context.maxOutputBytes)
    }

    private func decodeArguments(_ argumentsJSON: Data) throws -> [String: Value]? {
        guard !argumentsJSON.isEmpty else { return nil }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: argumentsJSON, options: [])
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

        if let bool = json as? Bool {
            return .bool(bool)
        }

        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }

            let doubleValue = number.doubleValue
            if doubleValue.isFinite,
               floor(doubleValue) == doubleValue,
               doubleValue >= Double(Int.min),
               doubleValue <= Double(Int.max) {
                return .int(number.intValue)
            }
            return .double(doubleValue)
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

        return object.mapValues { unwrapSchemaValue($0) }
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
                if let mimeType = resource.mimeType, !mimeType.isEmpty {
                    return "[resource: \(resource.uri) \(mimeType)]"
                }
                return "[resource: \(resource.uri)]"
            case .resourceLink(let uri, let name, let title, _, let mimeType, _):
                var parts = ["resourceLink: \(name)", uri]
                if let title, !title.isEmpty {
                    parts.append("title=\(title)")
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

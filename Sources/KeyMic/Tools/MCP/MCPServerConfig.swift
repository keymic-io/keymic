import Foundation

public enum MCPTransportConfig: Sendable, Codable, Equatable {
    case stdio(command: String, args: [String], env: [String: String]?)
    case http(url: URL)
    case sse(url: URL)

    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case args
        case env
        case url
    }

    private enum TransportType: String, Codable {
        case stdio
        case http
        case sse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)

        guard let type = TransportType(rawValue: rawType) else {
            throw MCPClientError.unsupportedTransport(rawType)
        }

        switch type {
        case .stdio:
            let command = try container.decode(String.self, forKey: .command)
            let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            let env = try container.decodeIfPresent([String: String].self, forKey: .env)
            self = .stdio(command: command, args: args, env: env)
        case .http:
            self = .http(url: try Self.decodeAbsoluteURL(from: container, forKey: .url))
        case .sse:
            self = .sse(url: try Self.decodeAbsoluteURL(from: container, forKey: .url))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .stdio(let command, let args, let env):
            try container.encode(TransportType.stdio.rawValue, forKey: .type)
            try container.encode(command, forKey: .command)
            if !args.isEmpty {
                try container.encode(args, forKey: .args)
            }
            if let env {
                try container.encode(env, forKey: .env)
            }
        case .http(let url):
            try container.encode(TransportType.http.rawValue, forKey: .type)
            try container.encode(url, forKey: .url)
        case .sse(let url):
            try container.encode(TransportType.sse.rawValue, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }

    private static func decodeAbsoluteURL(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> URL {
        let rawURL = try container.decode(String.self, forKey: key)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected an absolute HTTP(S) URL string with a host."
            )
        }
        return url
    }
}

public enum MCPAuthConfig: Sendable, Codable, Equatable {
    case none
    case bearer(accountKey: String)
    case oauth(accountKey: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case accountKey
    }

    private enum AuthType: String {
        case none
        case bearer
        case oauth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)

        guard let type = AuthType(rawValue: rawType) else {
            throw MCPClientError.configInvalid(reason: "Unknown MCP auth type '\(rawType)'.")
        }

        switch type {
        case .none:
            self = .none
        case .bearer:
            self = .bearer(accountKey: try container.decode(String.self, forKey: .accountKey))
        case .oauth:
            self = .oauth(accountKey: try container.decode(String.self, forKey: .accountKey))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .none:
            try container.encode(AuthType.none.rawValue, forKey: .type)
        case .bearer(let accountKey):
            try container.encode(AuthType.bearer.rawValue, forKey: .type)
            try container.encode(accountKey, forKey: .accountKey)
        case .oauth(let accountKey):
            try container.encode(AuthType.oauth.rawValue, forKey: .type)
            try container.encode(accountKey, forKey: .accountKey)
        }
    }
}

public struct MCPTimeoutConfig: Sendable, Codable, Equatable {
    public static let `default` = MCPTimeoutConfig()

    public let connectSeconds: Int
    public let toolCallSeconds: Int

    public init(connectSeconds: Int = 30, toolCallSeconds: Int = 120) {
        self.connectSeconds = connectSeconds
        self.toolCallSeconds = toolCallSeconds
    }
}

public struct MCPServerConfig: Sendable, Codable, Equatable, Identifiable {
    public let name: String
    public let transport: MCPTransportConfig
    public let auth: MCPAuthConfig
    public let timeout: MCPTimeoutConfig
    public let enabled: Bool

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name
        case transport
        case auth
        case timeout
        case enabled
    }

    public init(
        name: String,
        transport: MCPTransportConfig,
        auth: MCPAuthConfig = .none,
        timeout: MCPTimeoutConfig = .default,
        enabled: Bool = true
    ) {
        self.name = name
        self.transport = transport
        self.auth = auth
        self.timeout = timeout
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(MCPTransportConfig.self, forKey: .transport)
        auth = try container.decodeIfPresent(MCPAuthConfig.self, forKey: .auth) ?? .none
        timeout = try container.decodeIfPresent(MCPTimeoutConfig.self, forKey: .timeout) ?? .default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(transport, forKey: .transport)
        if auth != .none {
            try container.encode(auth, forKey: .auth)
        }
        if timeout != .default {
            try container.encode(timeout, forKey: .timeout)
        }
        if enabled != true {
            try container.encode(enabled, forKey: .enabled)
        }
    }
}

public struct MCPConfigDocument: Sendable, Codable, Equatable {
    public var servers: [MCPServerConfig]

    public init(servers: [MCPServerConfig] = []) {
        self.servers = servers
    }
}

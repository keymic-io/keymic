import Foundation
import os

public actor MCPClientManager {
    public struct ServerStatus: Sendable {
        public enum State: Sendable, Equatable {
            case disconnected
            case connecting
            case connected(toolCount: Int)
            case error(String)
        }

        public let name: String
        public let state: State
        public let lastChange: Date

        public init(name: String, state: State, lastChange: Date = Date()) {
            self.name = name
            self.state = state
            self.lastChange = lastChange
        }
    }

    private let configStore: MCPConfigStore
    private let tokenStore: MCPTokenStore
    private let logger = Logger(subsystem: "io.keymic.app", category: "MCP")

    private var clients: [String: MCPClient] = [:]
    private var registeredToolNames: Set<String> = []
    private var statuses: [String: ServerStatus] = [:]

    public init(configStore: MCPConfigStore = MCPConfigStore(), tokenStore: MCPTokenStore = MCPTokenStore()) {
        self.configStore = configStore
        self.tokenStore = tokenStore
    }

    public func allStatuses() -> [ServerStatus] {
        statuses.values.sorted { $0.name < $1.name }
    }

    public func status(for serverName: String) -> ServerStatus? {
        statuses[serverName]
    }

    private func setStatus(_ serverName: String, _ state: ServerStatus.State) {
        statuses[serverName] = ServerStatus(name: serverName, state: state)
    }

    public func loadAndConnectAll(registry: ToolRegistry) async {
        let document: MCPConfigDocument
        do {
            document = try configStore.load()
        } catch {
            logger.error("Failed to load MCP config: \(error.localizedDescription, privacy: .public)")
            return
        }

        for config in document.servers where config.enabled {
            await connectOne(config, registry: registry)
        }
    }

    private func connectOne(_ config: MCPServerConfig, registry: ToolRegistry) async {
        setStatus(config.name, .connecting)

        let bearerToken: String?
        do {
            bearerToken = try resolveBearerToken(for: config)
        } catch let error as MCPClientError {
            let message = error.localizedDescription
            setStatus(config.name, .error(message))
            logger.error("MCP auth failed for \(config.name, privacy: .public): \(message, privacy: .public)")
            return
        } catch {
            let message = "keychain error: \(error.localizedDescription)"
            setStatus(config.name, .error(message))
            logger.error("MCP keychain read failed for \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let client = MCPClient(config: config, bearerToken: bearerToken)
        var localRegisteredToolNames: [String] = []

        do {
            try await client.connect()
            let descriptors = try await client.listTools()

            for descriptor in descriptors {
                let adapter = try MCPToolAdapter.make(from: descriptor, serverName: config.name, client: client)
                try await registry.register(adapter, replacingExisting: true)
                registeredToolNames.insert(adapter.name)
                localRegisteredToolNames.append(adapter.name)
            }

            clients[config.name] = client
            setStatus(config.name, .connected(toolCount: descriptors.count))
        } catch {
            await client.disconnect()
            for toolName in localRegisteredToolNames {
                await registry.unregister(name: toolName)
                registeredToolNames.remove(toolName)
            }

            let message = error.localizedDescription
            setStatus(config.name, .error(message))
            logger.error("MCP connect failed for \(config.name, privacy: .public): \(message, privacy: .public)")
        }
    }

    private func resolveBearerToken(for config: MCPServerConfig) throws -> String? {
        let accountKey: String
        switch config.auth {
        case .none:
            return nil
        case .bearer(let key), .oauth(let key):
            accountKey = key
        }

        guard let token = try tokenStore.read(account: accountKey), !token.isEmpty else {
            throw MCPClientError.authMissing(server: config.name, accountKey: accountKey)
        }
        return token
    }

    public func reloadConfig(registry: ToolRegistry) async {
        await disconnectAll(registry: registry)
        await loadAndConnectAll(registry: registry)
    }

    public func disconnectAll(registry: ToolRegistry) async {
        for client in clients.values {
            await client.disconnect()
        }

        for toolName in registeredToolNames {
            await registry.unregister(name: toolName)
        }

        clients.removeAll()
        registeredToolNames.removeAll()
        statuses.removeAll()
    }

    public func disconnect(serverName: String, registry: ToolRegistry) async {
        let client = clients.removeValue(forKey: serverName)
        await client?.disconnect()

        let prefix = "\(serverName)."
        let namesToRemove = registeredToolNames.filter { $0.hasPrefix(prefix) }
        for toolName in namesToRemove {
            await registry.unregister(name: toolName)
            registeredToolNames.remove(toolName)
        }

        setStatus(serverName, .disconnected)
    }

    public func connectedServers() -> [String] {
        clients.keys.sorted()
    }
}

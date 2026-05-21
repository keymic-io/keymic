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

    private struct StaleConnection: Error {}

    struct RegisteredTool: Sendable, Hashable {
        let name: String
        let registrationID: UUID
    }

    private let configStore: MCPConfigStore
    private let tokenStore: MCPTokenStore
    private let logger = Logger(subsystem: "io.keymic.app", category: "MCP")

    private var clients: [String: MCPClient] = [:]
    private var registeredToolsByServer: [String: Set<RegisteredTool>] = [:]
    private var statuses: [String: ServerStatus] = [:]
    private var generation: UInt64 = 0

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

    private func advanceGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func isCurrentGeneration(_ capturedGeneration: UInt64) -> Bool {
        generation == capturedGeneration
    }

    public func loadAndConnectAll(registry: ToolRegistry) async {
        let document: MCPConfigDocument
        do {
            document = try configStore.load()
        } catch {
            logger.error("Failed to load MCP config: \(error.localizedDescription, privacy: .public)")
            return
        }

        let capturedGeneration = advanceGeneration()
        await cleanupCurrentState(registry: registry)

        guard isCurrentGeneration(capturedGeneration) else { return }

        for config in document.servers where config.enabled {
            guard isCurrentGeneration(capturedGeneration) else { return }
            await connectOne(config, registry: registry, generation: capturedGeneration)
        }
    }

    private func connectOne(_ config: MCPServerConfig, registry: ToolRegistry, generation capturedGeneration: UInt64) async {
        guard isCurrentGeneration(capturedGeneration) else { return }
        setStatus(config.name, .connecting)

        let bearerToken: String?
        do {
            bearerToken = try resolveBearerToken(for: config)
        } catch let error as MCPClientError {
            guard isCurrentGeneration(capturedGeneration) else { return }
            let message = error.localizedDescription
            setStatus(config.name, .error(message))
            logger.error("MCP auth failed for \(config.name, privacy: .public): \(message, privacy: .public)")
            return
        } catch {
            guard isCurrentGeneration(capturedGeneration) else { return }
            let message = "keychain error: \(error.localizedDescription)"
            setStatus(config.name, .error(message))
            logger.error("MCP keychain read failed for \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let client = MCPClient(config: config, bearerToken: bearerToken)
        var localRegisteredTools: Set<RegisteredTool> = []

        do {
            try await client.connect()
            guard isCurrentGeneration(capturedGeneration) else {
                await cleanupStale(client: client, registeredTools: localRegisteredTools, registry: registry)
                return
            }

            let descriptors = try await client.listTools()
            guard isCurrentGeneration(capturedGeneration) else {
                await cleanupStale(client: client, registeredTools: localRegisteredTools, registry: registry)
                return
            }

            for descriptor in descriptors {
                guard isCurrentGeneration(capturedGeneration) else {
                    await cleanupStale(client: client, registeredTools: localRegisteredTools, registry: registry)
                    return
                }

                do {
                    let adapter = try MCPToolAdapter.make(from: descriptor, serverName: config.name, client: client)
                    let registeredTool = try await registerAdapter(
                        adapter,
                        forServer: config.name,
                        registry: registry,
                        generation: capturedGeneration
                    )
                    localRegisteredTools.insert(registeredTool)
                } catch is StaleConnection {
                    await cleanupStale(client: client, registeredTools: localRegisteredTools, registry: registry)
                    return
                } catch {
                    logger.error("Failed to register MCP tool from \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            guard isCurrentGeneration(capturedGeneration) else {
                await cleanupStale(client: client, registeredTools: localRegisteredTools, registry: registry)
                return
            }

            clients[config.name] = client
            setStatus(config.name, .connected(toolCount: localRegisteredTools.count))
        } catch {
            await cleanupStale(client: client, registeredTools: localRegisteredTools, registry: registry)

            guard isCurrentGeneration(capturedGeneration) else { return }

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

    @discardableResult
    func registerAdapter(
        _ adapter: MCPToolAdapter,
        forServer serverName: String,
        registry: ToolRegistry,
        generation capturedGeneration: UInt64? = nil
    ) async throws -> RegisteredTool {
        let registeredTool = RegisteredTool(name: adapter.name, registrationID: adapter.registrationID)

        try await registry.register(adapter, replacingExisting: true)

        if let capturedGeneration, !isCurrentGeneration(capturedGeneration) {
            await unregisterAdapter(name: registeredTool.name, registrationID: registeredTool.registrationID, registry: registry)
            throw StaleConnection()
        }

        registeredToolsByServer[serverName, default: []].insert(registeredTool)
        return registeredTool
    }

    @discardableResult
    func unregisterAdapter(name: String, registrationID: UUID, registry: ToolRegistry) async -> Bool {
        await registry.unregister(name: name) { tool in
            guard let adapter = tool as? MCPToolAdapter else { return false }
            return adapter.registrationID == registrationID
        }
    }

    public func reloadConfig(registry: ToolRegistry) async {
        await loadAndConnectAll(registry: registry)
    }

    public func disconnectAll(registry: ToolRegistry) async {
        _ = advanceGeneration()
        await cleanupCurrentState(registry: registry)
    }

    public func disconnect(serverName: String, registry: ToolRegistry) async {
        let capturedGeneration = advanceGeneration()
        let client = clients.removeValue(forKey: serverName)
        let registeredTools = registeredToolsByServer.removeValue(forKey: serverName) ?? []

        await client?.disconnect()

        for registeredTool in registeredTools {
            await unregisterAdapter(name: registeredTool.name, registrationID: registeredTool.registrationID, registry: registry)
        }

        guard isCurrentGeneration(capturedGeneration) else { return }
        setStatus(serverName, .disconnected)
    }

    public func connectedServers() -> [String] {
        clients.keys.sorted()
    }

    private func cleanupCurrentState(registry: ToolRegistry) async {
        let clientsToDisconnect = clients.values
        let toolsToUnregister = registeredToolsByServer.values.flatMap { $0 }

        clients.removeAll()
        registeredToolsByServer.removeAll()
        statuses.removeAll()

        for client in clientsToDisconnect {
            await client.disconnect()
        }

        for registeredTool in toolsToUnregister {
            await unregisterAdapter(name: registeredTool.name, registrationID: registeredTool.registrationID, registry: registry)
        }
    }

    private func cleanupStale(client: MCPClient, registeredTools: Set<RegisteredTool>, registry: ToolRegistry) async {
        await client.disconnect()

        for registeredTool in registeredTools {
            await unregisterAdapter(name: registeredTool.name, registrationID: registeredTool.registrationID, registry: registry)
        }
    }
}

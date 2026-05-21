import Foundation
import MCP

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

public actor MCPClient: MCPClientProtocol {
    private let config: MCPServerConfig
    private let bearerToken: String?
    private let client: Client

    private var transport: (any Transport)?
    private var stdioProcess: Process?
    private var stderrDrainTask: Task<Void, Never>?
    private var connected = false
    private var connectTask: Task<Void, Error>?

    public private(set) var instructions: String?

    public init(config: MCPServerConfig, bearerToken: String? = nil) {
        self.config = config
        self.bearerToken = bearerToken
        self.client = Client(name: "KeyMic", version: "0.0.0")
    }

    public var serverName: String {
        config.name
    }

    public var isConnected: Bool {
        connected
    }

    public func connect() async throws {
        guard !connected else { return }

        if let connectTask {
            return try await connectTask.value
        }

        let connectTask = Task {
            try await self.runConnectFlow()
        }
        self.connectTask = connectTask

        do {
            try await connectTask.value
            self.connectTask = nil
        } catch {
            self.connectTask = nil
            throw error
        }
    }

    public func disconnect() async {
        await disconnectResources()
    }

    public func listTools() async throws -> [MCP.Tool] {
        guard connected else {
            throw MCPClientError.notConnected(server: config.name)
        }

        var tools: [MCP.Tool] = []
        var cursor: String?

        repeat {
            let result = try await client.listTools(cursor: cursor)
            tools.append(contentsOf: result.tools)
            cursor = result.nextCursor
        } while cursor != nil

        return tools
    }

    public func callTool(name: String, arguments: [String: Value]?) async throws -> (content: [MCP.Tool.Content], isError: Bool) {
        guard connected else {
            throw MCPClientError.notConnected(server: config.name)
        }

        let context: RequestContext<CallTool.Result>
        do {
            context = try await client.callTool(name: name, arguments: arguments, meta: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPClientError.toolCallFailed(server: config.name, tool: name, reason: error.localizedDescription)
        }

        do {
            let result = try await withTimeout(seconds: config.timeout.toolCallSeconds) {
                try await context.value
            }
            return (content: result.content, isError: result.isError ?? false)
        } catch is TimeoutError {
            try? await client.cancelRequest(context.requestID, reason: "Timed out calling tool \(name) on server \(config.name)")
            throw MCPClientError.toolCallTimeout(server: config.name, tool: name)
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            try? await client.cancelRequest(context.requestID, reason: "Cancelled calling tool \(name) on server \(config.name)")
            throw CancellationError()
        } catch {
            throw MCPClientError.toolCallFailed(server: config.name, tool: name, reason: error.localizedDescription)
        }
    }

    private func runConnectFlow() async throws {
        do {
            let result = try await withTimeout(seconds: config.timeout.connectSeconds) {
                try await self.connectImpl()
            }
            instructions = result.instructions
            connected = true
        } catch is TimeoutError {
            await disconnectResources()
            throw MCPClientError.connectionTimeout(server: config.name)
        } catch is CancellationError {
            await disconnectResources()
            throw CancellationError()
        } catch let error as MCPClientError {
            await disconnectResources()
            throw error
        } catch {
            await disconnectResources()
            throw MCPClientError.connectionFailed(server: config.name, reason: error.localizedDescription)
        }
    }

    private func connectImpl() async throws -> Initialize.Result {
        switch config.transport {
        case .stdio(let command, let args, let env):
            let transport = try startStdioTransport(command: command, args: args, env: env)
            self.transport = transport
            return try await client.connect(transport: transport)
        case .http(let url):
            let transport = makeHTTPTransport(endpoint: url, streaming: false)
            self.transport = transport
            return try await client.connect(transport: transport)
        case .sse(let url):
            let transport = makeHTTPTransport(endpoint: url, streaming: true)
            self.transport = transport
            return try await client.connect(transport: transport)
        }
    }

    private func startStdioTransport(command: String, args: [String], env: [String: String]?) throws -> StdioTransport {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()

        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }

        process.environment = mergedEnvironment(extra: env)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw MCPClientError.processLaunchFailed(server: config.name, reason: error.localizedDescription)
        }

        stdioProcess = process
        stderrDrainTask = Task {
            let handle = stderrPipe.fileHandleForReading
            do {
                for try await _ in handle.bytes {}
            } catch {
            }
            try? handle.close()
        }

        return StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )
    }

    private func makeHTTPTransport(endpoint: URL, streaming: Bool) -> HTTPClientTransport {
        HTTPClientTransport(
            endpoint: endpoint,
            streaming: streaming,
            sseInitializationTimeout: TimeInterval(config.timeout.connectSeconds),
            authorizer: nil,
            requestModifier: { [bearerToken] request in
                guard let bearerToken, !bearerToken.isEmpty else {
                    return request
                }

                var request = request
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                return request
            }
        )
    }

    private func mergedEnvironment(extra: [String: String]?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        if let extra {
            environment.merge(extra) { _, new in new }
        }

        if let bearerToken, !bearerToken.isEmpty {
            environment["MCP_BEARER_TOKEN"] = bearerToken
        }

        return environment
    }

    private func disconnectResources() async {
        await client.disconnect()
        transport = nil
        connected = false
        instructions = nil

        let stderrDrainTask = self.stderrDrainTask
        self.stderrDrainTask = nil
        stderrDrainTask?.cancel()

        let process = stdioProcess
        stdioProcess = nil

        if let process {
            await reapProcess(process)
        }
    }

    private func reapProcess(_ process: Process) async {
        guard process.isRunning else { return }

        process.terminate()

        let terminatedAfterTerm = await waitForProcessExit(process, timeoutSeconds: 1)
        guard !terminatedAfterTerm else { return }

        kill(process.processIdentifier, SIGKILL)
        _ = await waitForProcessExit(process, timeoutSeconds: 1)
    }
}

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func waitForProcessExit(_ process: Process, timeoutSeconds: TimeInterval) async -> Bool {
    if !process.isRunning {
        return true
    }

    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await withCheckedContinuation { continuation in
                Task.detached {
                    process.waitUntilExit()
                    continuation.resume(returning: ())
                }
            }
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

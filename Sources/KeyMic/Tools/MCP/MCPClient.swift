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
            return try await awaitConnectTask(connectTask)
        }

        let connectTask = Task {
            try await self.runConnectFlow()
        }
        self.connectTask = connectTask

        do {
            try await awaitConnectTask(connectTask)
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

    private func awaitConnectTask(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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
        let connectTask = self.connectTask
        self.connectTask = nil
        connectTask?.cancel()

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

private final class AsyncCompletion<T: Sendable>: @unchecked Sendable {
    private enum Completion {
        case success(T)
        case failure(Error)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var completion: Completion?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        let completion: Completion?

        lock.lock()
        if let existingCompletion = self.completion {
            completion = existingCompletion
        } else {
            self.continuation = continuation
            completion = nil
        }
        lock.unlock()

        if let completion {
            resume(continuation, with: completion)
        }
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = completion != nil
        if !shouldCancel {
            operationTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = completion != nil
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func succeed(_ value: T) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ completion: Completion) {
        let continuation: CheckedContinuation<T, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard self.completion == nil else {
            lock.unlock()
            return
        }

        self.completion = completion
        continuation = self.continuation
        self.continuation = nil
        operationTask = self.operationTask
        self.operationTask = nil
        timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()

        if let continuation {
            resume(continuation, with: completion)
        }
    }

    private func resume(_ continuation: CheckedContinuation<T, Error>, with completion: Completion) {
        switch completion {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class ProcessExitCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var waitTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        let result: Bool?

        lock.lock()
        if let existingResult = self.result {
            result = existingResult
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()

        if let result {
            continuation.resume(returning: result)
        }
    }

    func setWaitTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel {
            waitTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func finish(_ result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>?
        let waitTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }

        self.result = result
        continuation = self.continuation
        self.continuation = nil
        waitTask = self.waitTask
        self.waitTask = nil
        timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        waitTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: result)
    }
}

private func withTimeout<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let completion = AsyncCompletion<T>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            completion.setContinuation(continuation)

            let operationTask = Task {
                do {
                    try Task.checkCancellation()
                    let result = try await operation()
                    completion.succeed(result)
                } catch {
                    completion.fail(error)
                }
            }
            completion.setOperationTask(operationTask)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    completion.fail(TimeoutError())
                } catch is CancellationError {
                } catch {
                    completion.fail(error)
                }
            }
            completion.setTimeoutTask(timeoutTask)
        }
    } onCancel: {
        completion.cancel()
    }
}

private func waitForProcessExit(_ process: Process, timeoutSeconds: TimeInterval) async -> Bool {
    if !process.isRunning {
        return true
    }

    let completion = ProcessExitCompletion()

    return await withCheckedContinuation { continuation in
        completion.setContinuation(continuation)

        let waitTask = Task.detached {
            process.waitUntilExit()
            completion.finish(true)
        }
        completion.setWaitTask(waitTask)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                completion.finish(false)
            } catch {
            }
        }
        completion.setTimeoutTask(timeoutTask)
    }
}

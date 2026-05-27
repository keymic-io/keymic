import Foundation

@main
struct WithTimeoutTests {
    static func main() async throws {
        try await testReturnsValueWhenFastEnough()
        try await testThrowsAgentTimeoutErrorWhenSlow()
        try await testRethrowsOperationError()
        print("WithTimeoutTests passed")
    }

    static func testReturnsValueWhenFastEnough() async throws {
        let result = try await withTimeout(seconds: 1.0) {
            return 42
        }
        precondition(result == 42)
    }

    static func testThrowsAgentTimeoutErrorWhenSlow() async throws {
        do {
            _ = try await withTimeout(seconds: 0.1) { () -> Int in
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 s
                return 0
            }
            preconditionFailure("expected AgentTimeoutError")
        } catch is AgentTimeoutError {
            // expected
        }
    }

    static func testRethrowsOperationError() async throws {
        struct Boom: Error {}
        do {
            _ = try await withTimeout(seconds: 1.0) { () -> Int in
                throw Boom()
            }
            preconditionFailure("expected Boom")
        } catch is Boom {
            // expected
        }
    }
}

import Foundation

@main
struct AgentMessageTests {
    static func main() throws {
        try testRoundTripSystem()
        try testRoundTripUser()
        try testRoundTripAssistantWithToolCalls()
        try testRoundTripToolResult()
        testToolCallEquatable()
        testConvenienceConstructors()
        print("AgentMessageTests passed")
    }

    static func testRoundTripSystem() throws {
        let msg = AgentMessage.system("You are an agent.")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        precondition(decoded == msg, "system message round-trip failed")
        precondition(decoded.role == .system)
        precondition(decoded.content == "You are an agent.")
        precondition(decoded.toolCalls == nil)
        precondition(decoded.toolCallId == nil)
    }

    static func testRoundTripUser() throws {
        let msg = AgentMessage.user("hi")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        precondition(decoded == msg)
        precondition(decoded.role == .user)
    }

    static func testRoundTripAssistantWithToolCalls() throws {
        let call = AgentToolCall(id: "call_1", name: "Read", argumentsJSON: "{\"path\":\"/tmp/x\"}")
        let msg = AgentMessage.assistant(content: "", toolCalls: [call])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        precondition(decoded == msg, "assistant+toolCalls round-trip failed")
        precondition(decoded.toolCalls?.count == 1)
        precondition(decoded.toolCalls?[0].id == "call_1")
        precondition(decoded.toolCalls?[0].name == "Read")
        precondition(decoded.toolCalls?[0].argumentsJSON == "{\"path\":\"/tmp/x\"}")
    }

    static func testRoundTripToolResult() throws {
        let msg = AgentMessage.tool(content: "file content", toolCallId: "call_1")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        precondition(decoded == msg)
        precondition(decoded.role == .tool)
        precondition(decoded.toolCallId == "call_1")
    }

    static func testToolCallEquatable() {
        let a = AgentToolCall(id: "x", name: "Bash", argumentsJSON: "{}")
        let b = AgentToolCall(id: "x", name: "Bash", argumentsJSON: "{}")
        let c = AgentToolCall(id: "y", name: "Bash", argumentsJSON: "{}")
        precondition(a == b)
        precondition(a != c)
    }

    static func testConvenienceConstructors() {
        precondition(AgentMessage.system("s").role == .system)
        precondition(AgentMessage.user("u").role == .user)
        precondition(AgentMessage.assistant(content: "a").role == .assistant)
        precondition(AgentMessage.tool(content: "t", toolCallId: "id").role == .tool)
    }
}

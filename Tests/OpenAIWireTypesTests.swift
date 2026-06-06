import Foundation

@main
struct OpenAIWireTypesTests {
    static func main() throws {
        try testEncodeUserMessage()
        try testEncodeAssistantWithToolCalls()
        try testEncodeToolResultMessage()
        try testEncodeChatRequestWithTools()
        try testDecodeChatResponseTextOnly()
        try testDecodeChatResponseWithToolCalls()
        try testDecodeChatResponseNullContent()
        try testAnyJSONRoundTripNested()
        print("OpenAIWireTypesTests passed")
    }

    static func testEncodeUserMessage() throws {
        let msg = WireMessage(role: "user", content: "hi", toolCalls: nil, toolCallId: nil)
        let json = try encodeJSON(msg)
        precondition(json["role"] as? String == "user")
        precondition(json["content"] as? String == "hi")
        precondition(json["tool_calls"] == nil)
        precondition(json["tool_call_id"] == nil)
    }

    static func testEncodeAssistantWithToolCalls() throws {
        let call = WireToolCall(
            id: "call_1", type: "function",
            function: WireToolCallFunction(name: "Read", arguments: "{\"path\":\"/x\"}")
        )
        let msg = WireMessage(role: "assistant", content: "", toolCalls: [call], toolCallId: nil)
        let json = try encodeJSON(msg)
        precondition(json["role"] as? String == "assistant")
        // Content is always present; empty for assistant turns whose only payload is tool_calls.
        precondition(json["content"] as? String == "")
        let calls = json["tool_calls"] as! [[String: Any]]
        precondition(calls.count == 1)
        precondition(calls[0]["id"] as? String == "call_1")
        let function = calls[0]["function"] as! [String: Any]
        precondition(function["name"] as? String == "Read")
        precondition(function["arguments"] as? String == "{\"path\":\"/x\"}")
    }

    static func testEncodeToolResultMessage() throws {
        let msg = WireMessage(role: "tool", content: "file contents", toolCalls: nil, toolCallId: "call_1")
        let json = try encodeJSON(msg)
        precondition(json["tool_call_id"] as? String == "call_1")
        precondition(json["content"] as? String == "file contents")
    }

    static func testEncodeChatRequestWithTools() throws {
        let tool = WireTool(
            type: "function",
            function: WireToolFunction(
                name: "Read",
                description: "Read a file",
                parameters: AnyJSON([
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                ])
            )
        )
        let req = ChatRequest(
            model: "gpt-4o-mini",
            messages: [WireMessage(role: "user", content: "read /x", toolCalls: nil, toolCallId: nil)],
            tools: [tool],
            toolChoice: "auto"
        )
        let json = try encodeJSON(req)
        precondition(json["model"] as? String == "gpt-4o-mini")
        precondition(json["tool_choice"] as? String == "auto")
        let tools = json["tools"] as! [[String: Any]]
        precondition(tools.count == 1)
        let function = tools[0]["function"] as! [String: Any]
        let params = function["parameters"] as! [String: Any]
        precondition(params["type"] as? String == "object")
        precondition((params["required"] as! [String]) == ["path"])
    }

    static func testDecodeChatResponseTextOnly() throws {
        let raw = """
        {"id":"resp_1","model":"gpt-4o-mini","choices":[
          {"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}
        ]}
        """
        let resp = try JSONDecoder().decode(ChatResponse.self, from: Data(raw.utf8))
        precondition(resp.choices.count == 1)
        precondition(resp.choices[0].message.content == "hello")
        precondition(resp.choices[0].message.toolCalls == nil)
    }

    static func testDecodeChatResponseWithToolCalls() throws {
        let raw = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[
          {"id":"call_abc","type":"function","function":{"name":"Read","arguments":"{\\"path\\":\\"/x\\"}"}}
        ]},"finish_reason":"tool_calls"}]}
        """
        let resp = try JSONDecoder().decode(ChatResponse.self, from: Data(raw.utf8))
        let calls = resp.choices[0].message.toolCalls!
        precondition(calls.count == 1)
        precondition(calls[0].id == "call_abc")
        precondition(calls[0].function.name == "Read")
        precondition(calls[0].function.arguments == "{\"path\":\"/x\"}")
    }

    static func testDecodeChatResponseNullContent() throws {
        let raw = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"x","type":"function","function":{"name":"Read","arguments":""}}
        ]}}]}
        """
        let resp = try JSONDecoder().decode(ChatResponse.self, from: Data(raw.utf8))
        precondition(resp.choices[0].message.content == nil)
        precondition(resp.choices[0].message.toolCalls?.count == 1)
    }

    static func testAnyJSONRoundTripNested() throws {
        let original: [String: Any] = [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "abs path"],
                "limit": ["type": "integer"],
                "all": ["type": "boolean"],
            ],
            "required": ["path"],
        ]
        let wrapped = AnyJSON(original)
        let data = try JSONEncoder().encode(wrapped)
        let decoded = try JSONDecoder().decode(AnyJSON.self, from: data)
        precondition(wrapped == decoded, "AnyJSON round-trip lost fidelity")
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

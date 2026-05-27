import Foundation

@main
struct ToolSchemaBuilderTests {
    static func main() throws {
        testBuildEmpty()
        testBuildSingleTool()
        testBuildMultiplePreservesOrder()
        try testBuildEncodesParametersSchema()
        print("ToolSchemaBuilderTests passed")
    }

    static func testBuildEmpty() {
        let wire = ToolSchemaBuilder.build([])
        precondition(wire.isEmpty)
    }

    static func testBuildSingleTool() {
        let tool = StubTool(name: "Read", description: "Read a file",
                            schema: ["type": "object", "properties": [:]])
        let wire = ToolSchemaBuilder.build([tool])
        precondition(wire.count == 1)
        precondition(wire[0].type == "function")
        precondition(wire[0].function.name == "Read")
        precondition(wire[0].function.description == "Read a file")
    }

    static func testBuildMultiplePreservesOrder() {
        // ToolSchemaBuilder takes [any Tool] in whatever order — it does not re-sort.
        // ToolRegistry.all() is the layer that sorts; the builder respects input order.
        let tools: [any Tool] = [
            StubTool(name: "Bash", description: "b", schema: ["type": "object"]),
            StubTool(name: "Read", description: "r", schema: ["type": "object"]),
            StubTool(name: "Write", description: "w", schema: ["type": "object"]),
        ]
        let wire = ToolSchemaBuilder.build(tools)
        precondition(wire.map { $0.function.name } == ["Bash", "Read", "Write"])
    }

    static func testBuildEncodesParametersSchema() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "limit": ["type": "integer"],
            ],
            "required": ["path"],
        ]
        let tool = StubTool(name: "Read", description: "Read", schema: schema)
        let wire = ToolSchemaBuilder.build([tool])
        let data = try JSONEncoder().encode(wire[0])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let function = json["function"] as! [String: Any]
        let parameters = function["parameters"] as! [String: Any]
        precondition(parameters["type"] as? String == "object")
        precondition((parameters["required"] as! [String]) == ["path"])
        let props = parameters["properties"] as! [String: Any]
        precondition((props["path"] as! [String: Any])["type"] as? String == "string")
    }
}

struct StubTool: Tool, @unchecked Sendable {
    let name: String
    let description: String
    let parametersJSONSchema: [String: Any]

    init(name: String, description: String, schema: [String: Any]) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = schema
    }

    func call(argumentsJSON: Data, context: ToolContext) async throws -> String { "" }
}

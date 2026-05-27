import Foundation

/// Converts a sequence of `Tool` conformers into the OpenAI `tools` array shape.
///
/// Input order is preserved verbatim (caller controls sort order; `ToolRegistry.all()`
/// already returns tools sorted by name for deterministic prompt-cache keys).
enum ToolSchemaBuilder {
    static func build(_ tools: [any Tool]) -> [WireTool] {
        tools.map { tool in
            WireTool(
                type: "function",
                function: WireToolFunction(
                    name: tool.name,
                    description: tool.description,
                    parameters: AnyJSON(tool.parametersJSONSchema)
                )
            )
        }
    }
}

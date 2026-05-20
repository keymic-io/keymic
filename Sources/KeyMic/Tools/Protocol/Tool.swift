import Foundation

/// A tool that can be invoked by an agent. Inputs and outputs are exchanged
/// as JSON-encoded `Data` to allow heterogeneous tool arrays (`[any Tool]`)
/// and easy serialization to LLM tool_use protocols.
///
/// Conformers describe their input shape via a JSON Schema-shaped dictionary
/// (`parametersJSONSchema`) and decode the actual input bytes inside `call`.
///
/// Output is a string because most LLM APIs expect tool results as text.
/// If you need structured output, JSON-encode it inside the string.
public protocol Tool: Sendable {
    /// Unique tool name (used by LLM to invoke). Convention: PascalCase
    /// matching Claude Code (`Read`, `Write`, `Edit`, `Bash`, ...).
    var name: String { get }

    /// LLM-facing description. Should explain when to use the tool and how
    /// its parameters work.
    var description: String { get }

    /// JSON Schema describing the input. Must be a JSON-Schema-shaped
    /// dictionary with at least `"type": "object"` and `"properties"`.
    /// Used verbatim when constructing LLM tool definitions.
    var parametersJSONSchema: [String: Any] { get }

    /// Execute the tool. `argumentsJSON` is the raw bytes of the tool input
    /// (a JSON object matching `parametersJSONSchema`). Implementations
    /// decode it to their own input type via `JSONDecoder`.
    ///
    /// Throws on invalid input or runtime failure. Return the result as a
    /// string suitable for echoing back to the LLM.
    func call(argumentsJSON: Data, context: ToolContext) async throws -> String
}

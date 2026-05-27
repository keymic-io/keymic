import Foundation

/// Tool that activates a registered skill by name.
///
/// LLMs invoke this after seeing a skill name in `<available_skills>`. The tool
/// looks the skill up, rejects hotkey-only skills, lazily upgrades metadata-only
/// skills to fully-loaded instructions, and returns a formatted activation
/// payload. Permission enforcement for `allowed_tools` is deferred to the agent
/// session layer; this tool only reports the requested grants.
public struct ActivateSkillTool: Tool {
    public let name = "ActivateSkill"

    public let description = """
    Activate a skill to load its full instructions into context.

    Use this only for a skill listed in <available_skills>. The required `name`
    argument must exactly match the listed skill name. Do not guess names and do
    not fabricate a skill body before activation.

    Hotkey-only skills (disable_model_invocation: true) are not listed in
    <available_skills> and cannot be activated via this tool.
    """

    public nonisolated(unsafe) let parametersJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": [
                "type": "string",
                "description": "Skill name, exactly as shown in <available_skills>."
            ]
        ],
        "required": ["name"]
    ]

    private let registry: SkillRegistry
    private let loader: SkillLoader

    public init(registry: SkillRegistry, loader: SkillLoader = SkillLoader()) {
        self.registry = registry
        self.loader = loader
    }

    private struct Arguments: Decodable {
        let name: String
    }

    public func call(argumentsJSON: Data, context: ToolContext) async throws -> String {
        if context.isCancelled() { throw CancellationError() }

        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        let trimmedName = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SkillError.unknownSkill(name: arguments.name)
        }

        guard var skill = await registry.skill(named: trimmedName) else {
            if context.isCancelled() { throw CancellationError() }
            throw SkillError.unknownSkill(name: trimmedName)
        }
        if context.isCancelled() { throw CancellationError() }

        if skill.metadata.disableModelInvocation {
            throw SkillError.skillDisabledForModel(name: skill.metadata.name)
        }

        if !skill.isFullyLoaded {
            skill = try loader.loadFull(from: skill)
            await registry.update(skill)
            if context.isCancelled() { throw CancellationError() }
        }

        return Self.truncate(Self.formatActivation(skill), maxBytes: context.maxOutputBytes)
    }

    public static func formatActivation(_ skill: Skill) -> String {
        var parts: [String] = [
            "# Skill activated: \(skill.metadata.name)",
            skill.metadata.description,
            "",
            "---",
            skill.instructions ?? ""
        ]

        if let allowedTools = skill.metadata.allowedTools, !allowedTools.isEmpty {
            parts.append("")
            parts.append("<granted_tools>\(allowedTools)</granted_tools>")
        }

        return parts.joined(separator: "\n")
    }

    public static func availableSkillsBlock(_ skills: [Skill]) -> String {
        let available = skills
            .filter { !$0.metadata.disableModelInvocation }
            .sorted { $0.metadata.name < $1.metadata.name }

        guard !available.isEmpty else { return "" }

        var lines = ["<available_skills>"]
        for skill in available {
            lines.append("- \(skill.metadata.name): \(skill.metadata.description)")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return text }

        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }

        let marker = "\n... [output truncated] ...\n"
        let markerBytes = Array(marker.utf8)
        guard maxBytes > markerBytes.count else {
            return validUTF8Prefix(markerBytes, maxBytes: maxBytes)
        }

        let available = maxBytes - markerBytes.count
        let headBytes = available / 2
        let tailBytes = available - headBytes

        return validUTF8Prefix(bytes, maxBytes: headBytes)
            + marker
            + validUTF8Suffix(bytes, maxBytes: tailBytes)
    }

    private static func validUTF8Prefix(_ bytes: [UInt8], maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var length = min(maxBytes, bytes.count)
        while length > 0 {
            if let string = String(bytes: bytes.prefix(length), encoding: .utf8) {
                return string
            }
            length -= 1
        }
        return ""
    }

    private static func validUTF8Suffix(_ bytes: [UInt8], maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var start = max(0, bytes.count - maxBytes)
        while start < bytes.count {
            if let string = String(bytes: bytes[start...], encoding: .utf8) {
                return string
            }
            start += 1
        }
        return ""
    }
}

import Foundation

/// MainActor-scoped helper consumed by all three Plan-6 entry points
/// (`SkillHotkeyBridge` consumer, `HotkeyAction.runAgent`, `SettingsAgentPanel`).
///
/// Each `run*` method constructs a fresh `AgentSession`, starts a detached `Task`
/// consuming the stream and forwarding events to the supplied sink, and returns
/// the `Task` so the caller may `.cancel()` it. Errors and lifecycle are handled
/// inside the detached task — caller never deals with `try`.
@MainActor
final class AgentRunner {
    private let registry: ToolRegistry
    private let skillRegistry: SkillRegistry
    private let configProvider: @Sendable () -> AgentConfig

    /// Default system prompt for `runForHotkey` when no skill body is available.
    nonisolated static let hotkeyDefaultSystemPrompt =
        "You are KeyMic's agent. Use the available tools to fulfill the user's request. Be concise."

    /// Constant userMessage for `runForSkill` runs — avoids sending an empty user turn.
    nonisolated static let skillProceedMessage = "Proceed."

    init(
        registry: ToolRegistry,
        skillRegistry: SkillRegistry,
        configProvider: @escaping @Sendable () -> AgentConfig = { AgentConfig.fromDefaults() }
    ) {
        self.registry = registry
        self.skillRegistry = skillRegistry
        self.configProvider = configProvider
    }

    /// Hotkey-triggered skill activation. Reads `skill.instructions` as the system
    /// prompt and `skill.metadata.allowedTools` as the allow-set.
    @discardableResult
    func runForSkill(_ skill: Skill, sink: any AgentEventSink) -> Task<Void, Never> {
        let body = skill.instructions ?? ""
        let allowed = AllowedToolsParser.parse(skill.metadata.allowedTools)
        let session = AgentSession(registry: registry, config: configProvider())
        return Task.detached {
            for await event in session.run(
                systemPrompt: body.isEmpty ? nil : body,
                userMessage: AgentRunner.skillProceedMessage,
                allowedToolNames: allowed,
                priorMessages: [],
                options: AgentRunOptions(),
                toolContext: ToolContext()
            ) {
                await sink.receive(event)
            }
        }
    }

    /// Generic hotkey-triggered agent run with a free-text prompt. No skill context,
    /// full tool set, default system prompt.
    @discardableResult
    func runForHotkey(prompt: String, sink: any AgentEventSink) -> Task<Void, Never> {
        let session = AgentSession(registry: registry, config: configProvider())
        return Task.detached {
            for await event in session.run(
                systemPrompt: AgentRunner.hotkeyDefaultSystemPrompt,
                userMessage: prompt,
                allowedToolNames: nil,
                priorMessages: [],
                options: AgentRunOptions(),
                toolContext: ToolContext()
            ) {
                await sink.receive(event)
            }
        }
    }

    /// Settings-panel-driven run with full control over every parameter (panel
    /// supplies its own accumulated `priorMessages` for multi-turn UX).
    @discardableResult
    func runForSettings(
        systemPrompt: String?,
        userMessage: String,
        allowedToolNames: Set<String>?,
        priorMessages: [AgentMessage],
        options: AgentRunOptions = AgentRunOptions(),
        sink: any AgentEventSink
    ) -> Task<Void, Never> {
        let session = AgentSession(registry: registry, config: configProvider())
        return Task.detached {
            for await event in session.run(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                allowedToolNames: allowedToolNames,
                priorMessages: priorMessages,
                options: options,
                toolContext: ToolContext()
            ) {
                await sink.receive(event)
            }
        }
    }
}

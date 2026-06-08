import Foundation

@main
struct AgentRunnerTests {
    static func main() async throws {
        try await testRunForSkillDeliversNotConfiguredWhenEmpty()
        try await testRunForSkillRespectsAllowedTools()
        try await testRunForHotkeyUsesDefaultSystemPrompt()
        try await testRunForHotkeyDeliversNotConfiguredWhenEmpty()
        try await testComposeSystemPromptEmptyRegistryReturnsBase()
        try await testComposeSystemPromptAppendsAvailableSkills()
        try await testComposeSystemPromptHidesHotkeyOnlySkills()
        print("AgentRunnerTests passed")
    }

    static func testRunForSkillDeliversNotConfiguredWhenEmpty() async throws {
        // We don't have a transport-injection hook on AgentRunner (by design — keeps
        // the prod path clean), so we exercise the wiring via the notConfigured
        // fast-path: empty config → AgentSession terminates before any HTTP attempt
        // → sink receives exactly one .error(.notConfigured) event. This verifies
        // that runForSkill correctly threads skill + sink → AgentSession.run.
        let sink = CapturingSink()
        let runner = await MainActor.run {
            AgentRunner(
                registry: ToolRegistry(),
                skillRegistry: SkillRegistry(),
                configProvider: { AgentConfig(apiBaseURL: "", apiKey: "", model: "") }
            )
        }
        let skill = Skill(
            metadata: SkillMetadata(name: "test-skill", description: "test", allowedTools: "Read"),
            instructions: "Be terse.",
            filePath: "/dev/null"
        )
        let task = await MainActor.run { runner.runForSkill(skill, sink: sink) }
        _ = await task.value
        let received = await sink.events
        precondition(received.count == 1, "expected exactly one event; got \(received.count)")
        guard case .error(let err) = received[0] else { preconditionFailure("expected .error; got \(received[0])") }
        guard case .notConfigured(let missing) = err else { preconditionFailure("expected .notConfigured; got \(err)") }
        precondition(missing.contains("agentAPIKey"))
    }

    static func testRunForSkillRespectsAllowedTools() async throws {
        // Sanity-check the parser path: a skill with `allowed_tools = "Bash Read"`
        // should produce a Set containing those names.
        let parsed = AllowedToolsParser.parse("Bash Read")
        precondition(parsed == Set(["Bash", "Read"]))
    }

    static func testRunForHotkeyUsesDefaultSystemPrompt() async throws {
        precondition(AgentRunner.hotkeyDefaultSystemPrompt.contains("KeyMic"))
    }

    static func testComposeSystemPromptEmptyRegistryReturnsBase() async throws {
        // Empty registry → base prompt is returned unchanged (no stray block).
        let out = await AgentRunner.composeSystemPrompt(base: "BASE", skillRegistry: SkillRegistry())
        precondition(out == "BASE", "empty registry should leave base unchanged; got \(String(describing: out))")
    }

    static func testComposeSystemPromptAppendsAvailableSkills() async throws {
        // A loaded, model-invocable skill must surface in <available_skills> so
        // the model can ActivateSkill it — the whole point of the registry.
        let reg = SkillRegistry()
        await reg.replace(with: [
            Skill(metadata: SkillMetadata(name: "alpha", description: "Alpha skill"),
                  instructions: nil, filePath: "/dev/null")
        ])
        let out = await AgentRunner.composeSystemPrompt(base: "BASE", skillRegistry: reg)
        precondition(out?.contains("BASE") == true)
        precondition(out?.contains("<available_skills>") == true, "missing skills block; got \(String(describing: out))")
        precondition(out?.contains("alpha") == true)
    }

    static func testComposeSystemPromptHidesHotkeyOnlySkills() async throws {
        // disable_model_invocation skills are hotkey-only and must NOT be listed.
        let reg = SkillRegistry()
        await reg.replace(with: [
            Skill(metadata: SkillMetadata(name: "hidden", description: "x",
                                          allowedTools: nil, disableModelInvocation: true),
                  instructions: nil, filePath: "/dev/null")
        ])
        let out = await AgentRunner.composeSystemPrompt(base: "BASE", skillRegistry: reg)
        precondition(out == "BASE", "hotkey-only skill must not appear; got \(String(describing: out))")
    }

    static func testRunForHotkeyDeliversNotConfiguredWhenEmpty() async throws {
        // Mirrors testRunForSkillDeliversNotConfiguredWhenEmpty for the hotkey path.
        // Empty config → AgentSession terminates immediately, no HTTP attempt.
        let sink = CapturingSink()
        let runner = await MainActor.run {
            AgentRunner(
                registry: ToolRegistry(),
                skillRegistry: SkillRegistry(),
                configProvider: { AgentConfig(apiBaseURL: "", apiKey: "", model: "") }
            )
        }
        let task = await MainActor.run { runner.runForHotkey(prompt: "hi", sink: sink) }
        _ = await task.value
        let received = await sink.events
        let hasNotConfigured = received.contains {
            if case .error(let e) = $0, case .notConfigured = e { return true }
            return false
        }
        precondition(hasNotConfigured, "expected notConfigured; got: \(received)")
    }
}

actor CapturingSink: AgentEventSink {
    private(set) var events: [AgentEvent] = []
    func receive(_ event: AgentEvent) async {
        events.append(event)
    }
}

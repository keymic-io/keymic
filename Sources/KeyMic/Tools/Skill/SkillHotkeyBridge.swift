import Foundation
import os

/// Adapter that runs a skill when a hotkey bound to `HotkeyAction.runSkill` fires.
///
/// The hotkey path intentionally does not reject `disableModelInvocation` skills:
/// that flag hides skills from LLM-driven activation, while direct hotkey bindings
/// may still run hotkey-only skills.
public final class SkillHotkeyBridge: @unchecked Sendable {
    public typealias Consumer = @Sendable (_ skill: Skill) -> Void

    private static let logger = Logger(subsystem: "io.keymic.app", category: "SkillHotkeyBridge")

    private let registry: SkillRegistry
    private let loader: SkillLoader
    private let consume: Consumer

    public init(
        registry: SkillRegistry,
        loader: SkillLoader = SkillLoader(),
        consume: @escaping Consumer
    ) {
        self.registry = registry
        self.loader = loader
        self.consume = consume
    }

    /// Fire the skill named `name`. Safe to call from any thread; internally
    /// dispatches to a Task to talk to the registry actor. Errors are logged,
    /// never thrown.
    public func fire(name: String) {
        Task { await self.fireAsync(name: name) }
    }

    /// Async variant for callers that already live on a Task and for tests.
    public func fireAsync(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.logger.warning("runSkill fired with empty name; ignoring")
            return
        }

        guard var skill = await registry.skill(named: trimmed) else {
            Self.logger.warning("runSkill: unknown skill '\(trimmed, privacy: .public)'")
            return
        }

        if !skill.isFullyLoaded {
            do {
                skill = try loader.loadFull(from: skill)
                await registry.update(skill)
            } catch {
                Self.logger.error("runSkill: loadFull failed for '\(skill.metadata.name, privacy: .public)': \(String(describing: error), privacy: .public)")
                return
            }
        }

        consume(skill)
    }
}

import Foundation

/// Actor that owns the loaded set of skills.
///
/// Mirrors `ToolRegistry`'s shape. Differences:
/// - `register` throws on duplicate name unless `replacingExisting: true`.
/// - `replace(with:)` atomically swaps the whole set — used after reload.
/// - `availableForModel()` filters skills with `disableModelInvocation == true`
///   so the LLM's `<available_skills>` block does not include hotkey-only skills.
///
/// `replace(with:)` uses deterministic last-wins behavior for duplicate names in
/// the input array, matching dictionary assignment order in the explicit loop.
public actor SkillRegistry {
    private var skills: [String: Skill] = [:]

    public init() {}

    public func register(_ skill: Skill, replacingExisting: Bool = false) throws {
        if !replacingExisting, skills[skill.metadata.name] != nil {
            throw SkillError.duplicateSkill(name: skill.metadata.name)
        }
        skills[skill.metadata.name] = skill
    }

    /// Atomically replace the whole skill set. If `newSkills` contains duplicate
    /// names, the last skill for a name wins deterministically.
    public func replace(with newSkills: [Skill]) {
        var next: [String: Skill] = [:]
        for skill in newSkills {
            next[skill.metadata.name] = skill
        }
        skills = next
    }

    public func unregister(name: String) {
        skills.removeValue(forKey: name)
    }

    public func skill(named name: String) -> Skill? {
        skills[name]
    }

    /// Update the stored skill for `skill.metadata.name`, adding it if absent.
    /// Used after a metadata-only entry is upgraded to a fully-loaded skill.
    public func update(_ skill: Skill) {
        skills[skill.metadata.name] = skill
    }

    public func allNames() -> [String] {
        skills.keys.sorted()
    }

    /// All skills sorted by name. Deterministic ordering improves prompt cache hits.
    public func all() -> [Skill] {
        skills.keys.sorted().compactMap { skills[$0] }
    }

    /// Skills the LLM is permitted to discover/activate. Excludes
    /// `disableModelInvocation == true` skills.
    public func availableForModel() -> [Skill] {
        all().filter { !$0.metadata.disableModelInvocation }
    }

    public var count: Int { skills.count }
}

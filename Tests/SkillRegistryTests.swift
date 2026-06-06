import Foundation

private enum SkillRegistryTests {
    static func main() throws {
        try testRegisterAndLookup()
        try testRegisterRejectsDuplicate()
        try testRegisterReplacingExistingUpdatesStoredSkill()
        try testReplaceSwapsWholeSet()
        try testReplaceDuplicateNamesLastWins()
        try testAvailableForModelFiltersDisabled()
        try testSkillNamedReturnsDisabledSkill()
        try testUnregister()
        try testAllNamesSorted()
        try testAllSortedByName()
        try testUpdateReplacesStoredSkillBody()
        try testCount()
        print("SkillRegistryTests passed")
    }

    static func makeSkill(
        _ name: String,
        description: String? = nil,
        instructions: String? = "body",
        filePath: String? = nil,
        disableModelInvocation: Bool = false
    ) -> Skill {
        Skill(
            metadata: SkillMetadata(
                name: name,
                description: description ?? "desc of \(name)",
                disableModelInvocation: disableModelInvocation
            ),
            instructions: instructions,
            filePath: filePath ?? "/tmp/\(name).md"
        )
    }

    static func runAsync<T>(_ work: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    static func testRegisterAndLookup() throws {
        let registry = SkillRegistry()
        let skill = makeSkill("alpha")
        try runAsync { try await registry.register(skill) }
        let got = try runAsync { await registry.skill(named: "alpha") }
        guard got == skill else { fatalError("lookup failed: \(String(describing: got))") }
    }

    static func testRegisterRejectsDuplicate() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("alpha")) }
        do {
            try runAsync { try await registry.register(makeSkill("alpha")) }
            fatalError("expected duplicate error")
        } catch SkillError.duplicateSkill(let name) {
            guard name == "alpha" else { fatalError("duplicate name: \(name)") }
        }
    }

    static func testRegisterReplacingExistingUpdatesStoredSkill() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("alpha", description: "old", instructions: "old body")) }
        let replacement = makeSkill("alpha", description: "new", instructions: "new body", filePath: "/tmp/new-alpha.md")
        try runAsync { try await registry.register(replacement, replacingExisting: true) }
        let got = try runAsync { await registry.skill(named: "alpha") }
        let count = try runAsync { await registry.count }
        guard count == 1 else { fatalError("count after replacement: \(count)") }
        guard got == replacement else { fatalError("replacement not stored: \(String(describing: got))") }
    }

    static func testReplaceSwapsWholeSet() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("alpha")) }
        try runAsync { try await registry.register(makeSkill("beta")) }
        try runAsync { await registry.replace(with: [makeSkill("gamma")]) }
        let names = try runAsync { await registry.allNames() }
        guard names == ["gamma"] else { fatalError("names after replace: \(names)") }
    }

    static func testReplaceDuplicateNamesLastWins() throws {
        let registry = SkillRegistry()
        let first = makeSkill("alpha", description: "first")
        let second = makeSkill("alpha", description: "second")
        try runAsync { await registry.replace(with: [first, second]) }
        let got = try runAsync { await registry.skill(named: "alpha") }
        guard got?.metadata.description == "second" else {
            fatalError("replace duplicate names should use last skill, got: \(String(describing: got))")
        }
    }

    static func testAvailableForModelFiltersDisabled() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("on")) }
        try runAsync { try await registry.register(makeSkill("off", disableModelInvocation: true)) }
        let available = try runAsync { await registry.availableForModel() }
        guard available.map(\.metadata.name) == ["on"] else {
            fatalError("availableForModel: \(available.map(\.metadata.name))")
        }
    }

    static func testSkillNamedReturnsDisabledSkill() throws {
        let registry = SkillRegistry()
        let disabled = makeSkill("off", disableModelInvocation: true)
        try runAsync { try await registry.register(disabled) }
        let got = try runAsync { await registry.skill(named: "off") }
        guard got == disabled else { fatalError("skill(named:) must return disabled skill") }
    }

    static func testUnregister() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("alpha")) }
        try runAsync { await registry.unregister(name: "alpha") }
        let got = try runAsync { await registry.skill(named: "alpha") }
        let count = try runAsync { await registry.count }
        guard got == nil else { fatalError("expected nil after unregister") }
        guard count == 0 else { fatalError("count after unregister: \(count)") }
    }

    static func testAllNamesSorted() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("zeta")) }
        try runAsync { try await registry.register(makeSkill("alpha")) }
        try runAsync { try await registry.register(makeSkill("mid")) }
        let names = try runAsync { await registry.allNames() }
        guard names == ["alpha", "mid", "zeta"] else { fatalError("names: \(names)") }
    }

    static func testAllSortedByName() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("zeta")) }
        try runAsync { try await registry.register(makeSkill("alpha")) }
        try runAsync { try await registry.register(makeSkill("mid")) }
        let names = try runAsync { await registry.all().map(\.metadata.name) }
        guard names == ["alpha", "mid", "zeta"] else { fatalError("all order: \(names)") }
    }

    static func testUpdateReplacesStoredSkillBody() throws {
        let registry = SkillRegistry()
        try runAsync { try await registry.register(makeSkill("alpha", instructions: nil)) }
        let loaded = makeSkill("alpha", instructions: "loaded body")
        try runAsync { await registry.update(loaded) }
        let got = try runAsync { await registry.skill(named: "alpha") }
        guard got?.instructions == "loaded body" else { fatalError("update did not replace body: \(String(describing: got))") }
        guard got?.isFullyLoaded == true else { fatalError("updated skill should be fully loaded") }
    }

    static func testCount() throws {
        let registry = SkillRegistry()
        let initial = try runAsync { await registry.count }
        guard initial == 0 else { fatalError("initial count: \(initial)") }
        try runAsync { try await registry.register(makeSkill("alpha")) }
        try runAsync { try await registry.register(makeSkill("beta")) }
        let afterRegister = try runAsync { await registry.count }
        guard afterRegister == 2 else { fatalError("count after register: \(afterRegister)") }
        try runAsync { await registry.replace(with: [makeSkill("gamma")]) }
        let afterReplace = try runAsync { await registry.count }
        guard afterReplace == 1 else { fatalError("count after replace: \(afterReplace)") }
    }
}

@main
private enum SkillRegistryTestRunner {
    static func main() throws {
        try SkillRegistryTests.main()
    }
}

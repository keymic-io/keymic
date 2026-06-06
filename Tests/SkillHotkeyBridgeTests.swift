import Foundation

private enum SkillHotkeyBridgeTests {
    static func main() throws {
        try testFiresKnownFullyLoadedSkillOnceWithBody()
        try testIgnoresUnknownSkill()
        try testUpgradesMetadataOnlyBeforeConsuming()
        try testEmptyNameIsNoOp()
        try testDisabledHotkeyOnlySkillIsAllowed()
        try testLoadFailureIsSwallowed()
        print("SkillHotkeyBridgeTests passed")
    }

    static let fm = FileManager.default

    static func tmpDir() -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("keymic-skill-bridge-tests-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ content: String, to url: URL) {
        try! content.data(using: .utf8)!.write(to: url, options: .atomic)
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

    /// Thread-safe captured-skill collector for the bridge consumer.
    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var skills: [Skill] = []

        func push(_ skill: Skill) {
            lock.lock()
            skills.append(skill)
            lock.unlock()
        }

        func read() -> [Skill] {
            lock.lock()
            defer { lock.unlock() }
            return skills
        }
    }

    static func testFiresKnownFullyLoadedSkillOnceWithBody() throws {
        let dir = tmpDir()
        let file = dir.appendingPathComponent("alpha.md")
        write("---\nname: alpha\ndescription: a\n---\nalpha-body", to: file)

        let registry = SkillRegistry()
        try runAsync { try await registry.register(try SkillLoader().loadFull(from: file)) }
        let captured = Captured()
        let bridge = SkillHotkeyBridge(registry: registry, consume: { skill in captured.push(skill) })

        try runAsync { await bridge.fireAsync(name: "alpha") }

        let got = captured.read()
        guard got.count == 1 else { fatalError("expected 1 consumed skill, got \(got.count)") }
        guard got[0].metadata.name == "alpha" else { fatalError("name: \(got[0].metadata.name)") }
        guard got[0].instructions == "alpha-body" else { fatalError("body: \(String(describing: got[0].instructions))") }
    }

    static func testIgnoresUnknownSkill() throws {
        let registry = SkillRegistry()
        let captured = Captured()
        let bridge = SkillHotkeyBridge(registry: registry, consume: { skill in captured.push(skill) })

        try runAsync { await bridge.fireAsync(name: "ghost") }

        guard captured.read().isEmpty else { fatalError("must not consume unknown skill") }
    }

    static func testUpgradesMetadataOnlyBeforeConsuming() throws {
        let dir = tmpDir()
        let file = dir.appendingPathComponent("lazy.md")
        write("---\nname: lazy\ndescription: l\n---\nlazy-body", to: file)

        let registry = SkillRegistry()
        let metadataOnly = try SkillLoader().loadMetadata(from: file)
        guard !metadataOnly.isFullyLoaded else { fatalError("setup should be metadata-only") }
        try runAsync { try await registry.register(metadataOnly) }
        let captured = Captured()
        let bridge = SkillHotkeyBridge(registry: registry, consume: { skill in captured.push(skill) })

        try runAsync { await bridge.fireAsync(name: "lazy") }

        let got = captured.read()
        guard got.count == 1, got[0].instructions == "lazy-body" else {
            fatalError("expected upgraded body, got: \(got)")
        }
        let updated = try runAsync { await registry.skill(named: "lazy") }
        guard updated?.isFullyLoaded == true else { fatalError("registry did not store loaded skill") }
    }

    static func testEmptyNameIsNoOp() throws {
        let registry = SkillRegistry()
        let captured = Captured()
        let bridge = SkillHotkeyBridge(registry: registry, consume: { skill in captured.push(skill) })

        try runAsync { await bridge.fireAsync(name: "   \n\t") }

        guard captured.read().isEmpty else { fatalError("must not consume empty name") }
    }

    static func testDisabledHotkeyOnlySkillIsAllowed() throws {
        let dir = tmpDir()
        let file = dir.appendingPathComponent("hotkey-only.md")
        write("---\nname: hotkey-only\ndescription: h\ndisable_model_invocation: true\n---\nhotkey-body", to: file)

        let registry = SkillRegistry()
        try runAsync { try await registry.register(try SkillLoader().loadMetadata(from: file)) }
        let captured = Captured()
        let bridge = SkillHotkeyBridge(registry: registry, consume: { skill in captured.push(skill) })

        try runAsync { await bridge.fireAsync(name: "hotkey-only") }

        let got = captured.read()
        guard got.count == 1 else { fatalError("disabled hotkey-only skill should still consume once") }
        guard got[0].metadata.disableModelInvocation else { fatalError("setup lost disable flag") }
        guard got[0].instructions == "hotkey-body" else { fatalError("body: \(String(describing: got[0].instructions))") }
    }

    static func testLoadFailureIsSwallowed() throws {
        let missing = fm.temporaryDirectory.appendingPathComponent("missing-skill-\(UUID().uuidString).md")
        let skill = Skill(
            metadata: SkillMetadata(name: "missing", description: "missing file"),
            instructions: nil,
            filePath: missing.path
        )
        let registry = SkillRegistry()
        try runAsync { try await registry.register(skill) }
        let captured = Captured()
        let bridge = SkillHotkeyBridge(registry: registry, consume: { skill in captured.push(skill) })

        try runAsync { await bridge.fireAsync(name: "missing") }

        guard captured.read().isEmpty else { fatalError("load failure must not consume") }
    }
}

@main
private enum SkillHotkeyBridgeTestRunner {
    static func main() throws {
        try SkillHotkeyBridgeTests.main()
    }
}

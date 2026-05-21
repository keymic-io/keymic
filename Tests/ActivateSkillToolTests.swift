import Foundation

@main
struct ActivateSkillToolTests {
    static func main() async throws {
        try await testSchemaShape()
        try await testActivateReturnsBodyHeaderAndDescription()
        try await testActivateUnknownThrows()
        try await testActivateDisabledThrows()
        try await testActivateLazilyUpgradesMetadataOnly()
        try await testGrantedToolsBlockAppended()
        try await testAvailableSkillsBlockFiltersDisabledAndSorts()
        try await testEmptyWhitespaceNameThrowsUnknownWithOriginalName()
        try await testCancellationBeforeDecodeDoesNotProceed()
        try await testCancellationAfterAwaitThrows()
        try await testMaxOutputBytesTruncationKeepsValidUTF8()
        try await testInvalidJSONThrowsDecodingError()
        try await testMissingNameThrowsDecodingError()
        print("ActivateSkillToolTests passed")
    }

    static let fm = FileManager.default

    static func tmpDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("keymic-activate-skill-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ content: String, to url: URL) throws {
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    static func makeSkill(
        _ name: String,
        description: String? = nil,
        instructions: String? = "body of skill",
        allowedTools: String? = nil,
        disableModelInvocation: Bool = false,
        filePath: String? = nil
    ) -> Skill {
        Skill(
            metadata: SkillMetadata(
                name: name,
                description: description ?? "description of \(name)",
                allowedTools: allowedTools,
                disableModelInvocation: disableModelInvocation
            ),
            instructions: instructions,
            filePath: filePath ?? "/tmp/\(name).md"
        )
    }

    static func input(_ name: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["name": name])
    }

    static func testSchemaShape() async throws {
        let tool = ActivateSkillTool(registry: SkillRegistry())
        assertEqual(tool.name, "ActivateSkill")
        assertTrue(tool.description.contains("available_skills"), "description should mention available_skills")
        assertTrue(tool.description.contains("Hotkey-only"), "description should mention hotkey-only rejection")

        let schema = tool.parametersJSONSchema
        assertEqual(schema["type"] as? String, "object")
        assertEqual(schema["required"] as? [String], ["name"])
        let props = try require(schema["properties"] as? [String: Any], "properties")
        let nameProp = try require(props["name"] as? [String: Any], "name property")
        assertEqual(nameProp["type"] as? String, "string")
    }

    static func testActivateReturnsBodyHeaderAndDescription() async throws {
        let registry = SkillRegistry()
        try await registry.register(makeSkill("hello", description: "Greet the user", instructions: "Say hi.\nKeep it short."))
        let tool = ActivateSkillTool(registry: registry)

        let out = try await tool.call(argumentsJSON: input(" hello\n"), context: ToolContext())

        assertTrue(out.contains("# Skill activated: hello"), "missing header: \(out)")
        assertTrue(out.contains("Greet the user"), "missing description: \(out)")
        assertTrue(out.contains("---\nSay hi.\nKeep it short."), "missing body after separator: \(out)")
    }

    static func testActivateUnknownThrows() async throws {
        let tool = ActivateSkillTool(registry: SkillRegistry())
        do {
            _ = try await tool.call(argumentsJSON: input("ghost"), context: ToolContext())
            fail("expected unknown skill")
        } catch SkillError.unknownSkill(let name) {
            assertEqual(name, "ghost")
        }
    }

    static func testActivateDisabledThrows() async throws {
        let registry = SkillRegistry()
        try await registry.register(makeSkill("secret", disableModelInvocation: true))
        let tool = ActivateSkillTool(registry: registry)

        do {
            _ = try await tool.call(argumentsJSON: input("secret"), context: ToolContext())
            fail("expected disabled skill error")
        } catch SkillError.skillDisabledForModel(let name) {
            assertEqual(name, "secret")
        }
    }

    static func testActivateLazilyUpgradesMetadataOnly() async throws {
        let dir = try tmpDir()
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("lazy.md")
        try write("---\nname: lazy\ndescription: Lazy load\n---\nlazy body content", to: file)
        let metadataOnly = try SkillLoader().loadMetadata(from: file)
        assertTrue(!metadataOnly.isFullyLoaded, "setup should be metadata-only")

        let registry = SkillRegistry()
        try await registry.register(metadataOnly)
        let tool = ActivateSkillTool(registry: registry)

        let out = try await tool.call(argumentsJSON: input("lazy"), context: ToolContext())
        assertTrue(out.contains("lazy body content"), "missing lazy-loaded body: \(out)")

        let updated = try require(await registry.skill(named: "lazy"), "updated skill")
        assertTrue(updated.isFullyLoaded, "registry should store upgraded skill")
        assertEqual(updated.instructions, "lazy body content")
    }

    static func testGrantedToolsBlockAppended() async throws {
        let skill = makeSkill(
            "permy",
            instructions: "body",
            allowedTools: "Bash(git:*) Read Write"
        )

        let out = ActivateSkillTool.formatActivation(skill)
        assertTrue(out.hasSuffix("\n<granted_tools>Bash(git:*) Read Write</granted_tools>"), "granted tools block missing: \(out)")
    }

    static func testAvailableSkillsBlockFiltersDisabledAndSorts() async throws {
        let zeta = makeSkill("zeta", description: "Z desc", instructions: nil)
        let alpha = makeSkill("alpha", description: "A desc", instructions: nil)
        let hidden = makeSkill("hidden", description: "Hidden desc", instructions: nil, disableModelInvocation: true)

        let block = ActivateSkillTool.availableSkillsBlock([zeta, hidden, alpha])

        let expected = """
        <available_skills>
        - alpha: A desc
        - zeta: Z desc
        </available_skills>
        """
        assertEqual(block, expected)
        assertTrue(!block.contains("hidden"), "disabled skill should be filtered")
        assertEqual(ActivateSkillTool.availableSkillsBlock([]), "")
    }

    static func testEmptyWhitespaceNameThrowsUnknownWithOriginalName() async throws {
        let tool = ActivateSkillTool(registry: SkillRegistry())
        do {
            _ = try await tool.call(argumentsJSON: input("  \t\n"), context: ToolContext())
            fail("expected unknown skill")
        } catch SkillError.unknownSkill(let name) {
            assertEqual(name, "  \t\n")
        }
    }

    static func testCancellationBeforeDecodeDoesNotProceed() async throws {
        let tool = ActivateSkillTool(registry: SkillRegistry())
        let invalidJSON = Data("not json".utf8)
        do {
            _ = try await tool.call(argumentsJSON: invalidJSON, context: ToolContext(isCancelled: { true }))
            fail("expected cancellation")
        } catch is CancellationError {
            // ok: cancellation checked before decode, so invalid JSON is never decoded.
        }
    }

    static func testCancellationAfterAwaitThrows() async throws {
        let registry = SkillRegistry()
        try await registry.register(makeSkill("hello"))
        let tool = ActivateSkillTool(registry: registry)
        final class Toggle: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func cancelled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count >= 2
            }
        }
        let toggle = Toggle()

        do {
            _ = try await tool.call(argumentsJSON: input("hello"), context: ToolContext(isCancelled: { toggle.cancelled() }))
            fail("expected cancellation after registry await")
        } catch is CancellationError {
            // ok
        }
    }

    static func testMaxOutputBytesTruncationKeepsValidUTF8() async throws {
        let registry = SkillRegistry()
        try await registry.register(makeSkill("unicode", description: "Unicode", instructions: String(repeating: "你好🙂", count: 100)))
        let tool = ActivateSkillTool(registry: registry)
        let context = ToolContext(maxOutputBytes: 83)

        let out = try await tool.call(argumentsJSON: input("unicode"), context: context)

        assertTrue(out.utf8.count <= 83, "output exceeds byte limit: \(out.utf8.count)")
        assertTrue(out.data(using: .utf8) != nil, "output must be valid UTF-8")
        assertTrue(out.contains("[output truncated]"), "missing truncation marker: \(out)")
    }

    static func testInvalidJSONThrowsDecodingError() async throws {
        let tool = ActivateSkillTool(registry: SkillRegistry())
        do {
            _ = try await tool.call(argumentsJSON: Data("not json".utf8), context: ToolContext())
            fail("expected decoding error")
        } catch is DecodingError {
            // ok
        }
    }

    static func testMissingNameThrowsDecodingError() async throws {
        let tool = ActivateSkillTool(registry: SkillRegistry())
        do {
            _ = try await tool.call(argumentsJSON: Data("{}".utf8), context: ToolContext())
            fail("expected decoding error")
        } catch is DecodingError {
            // ok
        }
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    if actual != expected {
        fatalError(message.isEmpty ? "Expected \(expected), got \(actual)" : message)
    }
}

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fatalError(message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { fatalError("Missing required value: \(message)") }
    return value
}

func fail(_ message: String) -> Never {
    fatalError(message)
}

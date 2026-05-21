import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        print("FAIL: \(message). Expected \(expected), got \(actual)")
        Foundation.exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        Foundation.exit(1)
    }
}

func assertFalse(_ condition: Bool, _ message: String) {
    if condition {
        print("FAIL: \(message)")
        Foundation.exit(1)
    }
}

func assertNil<T>(_ value: T?, _ message: String) {
    if value != nil {
        print("FAIL: \(message). Expected nil")
        Foundation.exit(1)
    }
}

@main
struct SkillLoaderTests {
    static let loader = SkillLoader()
    static let fileManager = FileManager.default

    static func main() throws {
        try testMissingDirectoryReturnsEmpty()
        try testLoadsTwoSkillsSortedByName()
        try testMetadataOnlyDoesNotIncludeBody()
        try testFullLoadIncludesBodyAndPreservesWhitespace()
        try testRejectsMissingFrontmatter()
        try testRejectsInvalidName()
        try testRejectsMissingDescription()
        try testSkipsBadFileContinuesScan()
        try testDuplicateInSingleDirFirstAlphabeticalWins()
        try testEarlierDirectoryShadowsLaterDirectory()
        try testUpgradeMetadataOnlySkill()
        try testAllowedToolsAndDisableModelInvocationParsed()
        try testHyphenAliasesParsed()
        try testMarkdownExtensionAndHiddenFiles()
        try testAlreadyFullSkillReturnsUnchanged()
        print("SkillLoaderTests passed")
    }

    static func temporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("keymic-skill-loader-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    static func write(_ content: String, to url: URL) throws {
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    static func assertThrows<T>(_ expected: (SkillError) -> Bool, _ message: String, _ body: () throws -> T) {
        do {
            _ = try body()
            print("FAIL: \(message). Expected throw")
            Foundation.exit(1)
        } catch let error as SkillError {
            if !expected(error) {
                print("FAIL: \(message). Unexpected SkillError: \(error)")
                Foundation.exit(1)
            }
        } catch {
            print("FAIL: \(message). Unexpected error: \(error)")
            Foundation.exit(1)
        }
    }

    static func skillFile(name: String, description: String = "Description", body: String = "Body", extra: String = "") -> String {
        """
        ---
        name: \(name)
        description: \(description)
        \(extra)---
        \(body)
        """
    }

    static func testMissingDirectoryReturnsEmpty() throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("keymic-missing-skill-dir-\(UUID().uuidString)", isDirectory: true)
        assertEqual(loader.loadDirectory(directory), [], "missing directory returns empty")
    }

    static func testLoadsTwoSkillsSortedByName() throws {
        try withTemporaryDirectory { directory in
            try write(skillFile(name: "zeta", description: "Z"), to: directory.appendingPathComponent("a.md"))
            try write(skillFile(name: "alpha", description: "A"), to: directory.appendingPathComponent("z.md"))

            let skills = loader.loadDirectory(directory)

            assertEqual(skills.map(\.metadata.name), ["alpha", "zeta"], "loads skills sorted by name")
        }
    }

    static func testMetadataOnlyDoesNotIncludeBody() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "metadata-only", body: "Full body"), to: file)

            let skill = try loader.loadMetadata(from: file)

            assertNil(skill.instructions, "metadata-only skill omits instructions")
            assertFalse(skill.isFullyLoaded, "metadata-only skill is not fully loaded")
        }
    }

    static func testFullLoadIncludesBodyAndPreservesWhitespace() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            let body = "\n    keep leading blank and indentation\n  keep trailing spaces  \n\n"
            try write("---\nname: full-load\ndescription: Full load\n---\n\(body)", to: file)

            let skill = try loader.loadFull(from: file)

            assertEqual(skill.instructions, body, "full load preserves parser body whitespace exactly")
            assertTrue(skill.isFullyLoaded, "full load is fully loaded")
        }
    }

    static func testRejectsMissingFrontmatter() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("# No frontmatter\nBody", to: file)

            assertThrows({ if case .frontmatterMissing = $0 { return true }; return false }, "missing frontmatter rejected") {
                try loader.loadMetadata(from: file)
            }
        }
    }

    static func testRejectsInvalidName() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "Invalid_Name"), to: file)

            assertThrows({ if case .invalidName(let name, _) = $0 { return name == "Invalid_Name" }; return false }, "invalid name rejected") {
                try loader.loadMetadata(from: file)
            }
        }
    }

    static func testRejectsMissingDescription() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("---\nname: no-description\n---\nBody", to: file)

            assertThrows({ if case .requiredFieldMissing(_, let field) = $0 { return field == "description" }; return false }, "missing description rejected") {
                try loader.loadMetadata(from: file)
            }
        }
    }

    static func testSkipsBadFileContinuesScan() throws {
        try withTemporaryDirectory { directory in
            try write("No frontmatter", to: directory.appendingPathComponent("bad.md"))
            try write(skillFile(name: "good"), to: directory.appendingPathComponent("good.md"))

            let skills = loader.loadDirectory(directory)

            assertEqual(skills.map(\.metadata.name), ["good"], "bad file skipped while good file loads")
        }
    }

    static func testDuplicateInSingleDirFirstAlphabeticalWins() throws {
        try withTemporaryDirectory { directory in
            try write(skillFile(name: "duplicate", description: "First"), to: directory.appendingPathComponent("00-first.md"))
            try write(skillFile(name: "duplicate", description: "Second"), to: directory.appendingPathComponent("99-second.md"))

            let skills = loader.loadDirectory(directory)

            assertEqual(skills.count, 1, "duplicate skill skipped")
            assertEqual(skills.first?.metadata.description, "First", "first alphabetical duplicate wins")
        }
    }

    static func testEarlierDirectoryShadowsLaterDirectory() throws {
        let userDirectory = try temporaryDirectory()
        let bundledDirectory = try temporaryDirectory()
        defer {
            try? fileManager.removeItem(at: userDirectory)
            try? fileManager.removeItem(at: bundledDirectory)
        }
        try write(skillFile(name: "shared", description: "User"), to: userDirectory.appendingPathComponent("shared.md"))
        try write(skillFile(name: "shared", description: "Bundled"), to: bundledDirectory.appendingPathComponent("shared.md"))
        try write(skillFile(name: "other", description: "Other"), to: bundledDirectory.appendingPathComponent("other.md"))

        let skills = loader.loadDirectories([userDirectory, bundledDirectory])

        assertEqual(skills.map(\.metadata.name), ["other", "shared"], "loadDirectories returns sorted unique skills")
        assertEqual(skills.first { $0.metadata.name == "shared" }?.metadata.description, "User", "earlier directory shadows later")
    }

    static func testUpgradeMetadataOnlySkill() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "upgrade", body: "Upgrade body"), to: file)
            let metadataOnly = try loader.loadMetadata(from: file)

            let full = try loader.loadFull(from: metadataOnly)

            assertEqual(full.instructions, "Upgrade body", "metadata-only skill upgrades to full body")
            assertTrue(full.isFullyLoaded, "upgraded skill is fully loaded")
        }
    }

    static func testAllowedToolsAndDisableModelInvocationParsed() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "permissions", extra: "allowed_tools: \"Bash(git:*) Read\"\ndisable_model_invocation: true\n"), to: file)

            let skill = try loader.loadMetadata(from: file)

            assertEqual(skill.metadata.allowedTools, "Bash(git:*) Read", "allowed_tools parsed")
            assertTrue(skill.metadata.disableModelInvocation, "disable_model_invocation true parsed")
        }
    }

    static func testHyphenAliasesParsed() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "hyphen", extra: "allowed-tools: Write Edit\ndisable-model-invocation: true\n"), to: file)

            let skill = try loader.loadMetadata(from: file)

            assertEqual(skill.metadata.allowedTools, "Write Edit", "allowed-tools alias parsed")
            assertTrue(skill.metadata.disableModelInvocation, "disable-model-invocation alias parsed")
        }
    }

    static func testMarkdownExtensionAndHiddenFiles() throws {
        try withTemporaryDirectory { directory in
            try write(skillFile(name: "visible"), to: directory.appendingPathComponent("visible.markdown"))
            try write(skillFile(name: "uppercase"), to: directory.appendingPathComponent("uppercase.MD"))
            try write(skillFile(name: "hidden"), to: directory.appendingPathComponent(".hidden.md"))
            try write(skillFile(name: "ignored"), to: directory.appendingPathComponent("ignored.txt"))

            let skills = loader.loadDirectory(directory)

            assertEqual(skills.map(\.metadata.name), ["uppercase", "visible"], ".markdown and case-insensitive .md load while hidden/non-markdown skip")
        }
    }

    static func testAlreadyFullSkillReturnsUnchanged() throws {
        let skill = Skill(
            metadata: SkillMetadata(name: "loaded", description: "Loaded"),
            instructions: "Already loaded",
            filePath: "/tmp/does-not-need-to-exist.md"
        )

        let result = try loader.loadFull(from: skill)

        assertEqual(result, skill, "already full skill returned unchanged")
    }
}

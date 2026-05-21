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
        try testNonDirectoryReturnsEmpty()
        try testStrictMissingAndNonDirectoryReturnEmpty()
        try testLoadsTwoSkillsSortedByName()
        try testScanIsNonRecursive()
        try testMetadataOnlyDoesNotIncludeBody()
        try testFullLoadIncludesBodyAndPreservesWhitespace()
        try testRejectsMissingFile()
        try testRejectsMissingFrontmatter()
        try testRejectsMalformedMissingClosingMarker()
        try testRejectsEmptyName()
        try testRejectsInvalidName()
        try testTrimsNameBeforeValidation()
        try testRejectsMissingDescription()
        try testRejectsWhitespaceOnlyDescription()
        try testTrimsDescriptionForMetadata()
        try testSkipsBadFileContinuesScan()
        try testDuplicateInSingleDirFirstAlphabeticalWins()
        try testEarlierDirectoryShadowsLaterDirectory()
        try testUpgradeMetadataOnlySkill()
        try testAllowedToolsAndDisableModelInvocationParsed()
        try testDisableModelInvocationIsCaseInsensitiveAndWhitespaceNormalized()
        try testDisableModelInvocationFalseRemainsFalse()
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

    static func testNonDirectoryReturnsEmpty() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("not-a-directory.md")
            try write(skillFile(name: "not-dir"), to: file)

            assertEqual(loader.loadDirectory(file), [], "non-directory path returns empty")
        }
    }

    static func testStrictMissingAndNonDirectoryReturnEmpty() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing", isDirectory: true)
            let file = directory.appendingPathComponent("not-a-directory.md")
            try write(skillFile(name: "not-dir"), to: file)

            let missingSkills: [Skill] = try loader.loadDirectoryStrict(missing)
            let fileSkills: [Skill] = try loader.loadDirectoryStrict(file)

            assertEqual(missingSkills, [], "strict missing directory returns empty")
            assertEqual(fileSkills, [], "strict non-directory path returns empty")
        }
    }

    static func testLoadsTwoSkillsSortedByName() throws {
        try withTemporaryDirectory { directory in
            try write(skillFile(name: "zeta", description: "Z"), to: directory.appendingPathComponent("a.md"))
            try write(skillFile(name: "alpha", description: "A"), to: directory.appendingPathComponent("z.md"))

            let skills = loader.loadDirectory(directory)

            assertEqual(skills.map(\.metadata.name), ["alpha", "zeta"], "loads skills sorted by name")
        }
    }

    static func testScanIsNonRecursive() throws {
        try withTemporaryDirectory { directory in
            let child = directory.appendingPathComponent("child", isDirectory: true)
            try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
            try write(skillFile(name: "top"), to: directory.appendingPathComponent("top.md"))
            try write(skillFile(name: "nested"), to: child.appendingPathComponent("nested.md"))

            let skills = loader.loadDirectory(directory)

            assertEqual(skills.map(\.metadata.name), ["top"], "directory scan is non-recursive")
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

    static func testRejectsMissingFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("missing.md")

            assertThrows({ if case .skillFileNotFound = $0 { return true }; return false }, "missing file rejected") {
                try loader.loadMetadata(from: file)
            }
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

    static func testRejectsMalformedMissingClosingMarker() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("---\nname: malformed\ndescription: Missing close\nBody", to: file)

            assertThrows({ if case .frontmatterMalformed = $0 { return true }; return false }, "missing closing marker rejected as malformed") {
                try loader.loadMetadata(from: file)
            }
        }
    }

    static func testRejectsEmptyName() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("---\nname: \ndescription: Description\n---\nBody", to: file)

            assertThrows({ if case .requiredFieldMissing(_, let field) = $0 { return field == "name" }; return false }, "empty name rejected") {
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

    static func testTrimsNameBeforeValidation() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("---\nname: \" trimmed-name \"\ndescription: Description\n---\nBody", to: file)

            let skill = try loader.loadMetadata(from: file)

            assertEqual(skill.metadata.name, "trimmed-name", "name is trimmed before validation and storage")
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

    static func testRejectsWhitespaceOnlyDescription() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("---\nname: whitespace-description\ndescription: \"   \"\n---\nBody", to: file)

            assertThrows({ if case .requiredFieldMissing(_, let field) = $0 { return field == "description" }; return false }, "whitespace-only description rejected") {
                try loader.loadMetadata(from: file)
            }
        }
    }

    static func testTrimsDescriptionForMetadata() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write("---\nname: trimmed-description\ndescription: \"  Useful description  \"\n---\nBody", to: file)

            let skill = try loader.loadMetadata(from: file)

            assertEqual(skill.metadata.description, "Useful description", "description is trimmed for metadata")
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

    static func testDisableModelInvocationIsCaseInsensitiveAndWhitespaceNormalized() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "case-normalized", extra: "disable_model_invocation: \" TRUE \"\n"), to: file)

            let skill = try loader.loadMetadata(from: file)

            assertTrue(skill.metadata.disableModelInvocation, "disable_model_invocation is case-insensitive and whitespace-normalized")
        }
    }

    static func testDisableModelInvocationFalseRemainsFalse() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("skill.md")
            try write(skillFile(name: "not-disabled", extra: "disable_model_invocation: false\n"), to: file)

            let skill = try loader.loadMetadata(from: file)

            assertFalse(skill.metadata.disableModelInvocation, "disable_model_invocation false remains false")
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

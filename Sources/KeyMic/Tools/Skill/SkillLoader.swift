import Foundation
import os

public struct SkillLoader: Sendable {
    public static let logger = Logger(subsystem: "io.keymic.app", category: "SkillLoader")

    private let parser: SkillFrontmatterParser

    public init(parser: SkillFrontmatterParser = SkillFrontmatterParser()) {
        self.parser = parser
    }

    public func loadDirectory(_ directory: URL) -> [Skill] {
        do {
            return try loadDirectoryStrict(directory)
        } catch {
            Self.logger.error("loadDirectory(\(directory.path, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func loadDirectoryStrict(_ directory: URL) throws -> [Skill] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SkillError.skillFileUnreadable(path: directory.path, underlying: error.localizedDescription)
        }

        let markdownFiles = contents
            .filter { url in
                let pathExtension = url.pathExtension.lowercased()
                return pathExtension == "md" || pathExtension == "markdown"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var seen: Set<String> = []
        var skills: [Skill] = []
        for url in markdownFiles {
            do {
                let skill = try loadMetadata(from: url)
                if seen.contains(skill.metadata.name) {
                    Self.logger.warning("duplicate skill name '\(skill.metadata.name, privacy: .public)' at \(url.path, privacy: .public); first wins, skipping")
                    continue
                }
                seen.insert(skill.metadata.name)
                skills.append(skill)
            } catch {
                Self.logger.warning("skipping \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        return skills.sorted { $0.metadata.name < $1.metadata.name }
    }

    public func loadDirectories(_ directories: [URL]) -> [Skill] {
        var seen: Set<String> = []
        var skills: [Skill] = []

        for directory in directories {
            for skill in loadDirectory(directory) {
                if seen.contains(skill.metadata.name) {
                    Self.logger.info("skill '\(skill.metadata.name, privacy: .public)' from later directory is shadowed; skipping")
                    continue
                }
                seen.insert(skill.metadata.name)
                skills.append(skill)
            }
        }

        return skills.sorted { $0.metadata.name < $1.metadata.name }
    }

    public func loadMetadata(from url: URL) throws -> Skill {
        let (metadata, _) = try readAndParse(url)
        return Skill(metadata: metadata, instructions: nil, filePath: url.path)
    }

    public func loadFull(from url: URL) throws -> Skill {
        let (metadata, body) = try readAndParse(url)
        return Skill(metadata: metadata, instructions: body, filePath: url.path)
    }

    public func loadFull(from skill: Skill) throws -> Skill {
        guard !skill.isFullyLoaded else {
            return skill
        }
        return try loadFull(from: URL(fileURLWithPath: skill.filePath))
    }

    private func readAndParse(_ url: URL) throws -> (SkillMetadata, String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SkillError.skillFileNotFound(path: url.path)
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SkillError.skillFileUnreadable(path: url.path, underlying: error.localizedDescription)
        }

        guard parser.hasFrontmatter(content) else {
            throw SkillError.frontmatterMissing(path: url.path)
        }

        guard let parsed = parser.parse(content) else {
            throw SkillError.frontmatterMalformed(path: url.path, reason: "no closing --- found")
        }

        guard let rawName = parsed.fields["name"] else {
            throw SkillError.requiredFieldMissing(path: url.path, field: "name")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SkillError.requiredFieldMissing(path: url.path, field: "name")
        }

        guard SkillMetadata.isValidName(name) else {
            throw SkillError.invalidName(name: name, path: url.path)
        }

        guard let rawDescription = parsed.fields["description"] else {
            throw SkillError.requiredFieldMissing(path: url.path, field: "description")
        }
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw SkillError.requiredFieldMissing(path: url.path, field: "description")
        }

        let rawAllowedTools = parsed.fields["allowed_tools"] ?? parsed.fields["allowed-tools"]
        let trimmedAllowedTools = rawAllowedTools?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedTools = trimmedAllowedTools?.isEmpty == true ? nil : trimmedAllowedTools

        let rawDisableModelInvocation = parsed.fields["disable_model_invocation"]
            ?? parsed.fields["disable-model-invocation"]
            ?? "false"
        let disableModelInvocation = rawDisableModelInvocation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"

        let metadata = SkillMetadata(
            name: name,
            description: description,
            allowedTools: allowedTools,
            disableModelInvocation: disableModelInvocation
        )

        return (metadata, parsed.body)
    }
}

import Foundation

public struct SkillMetadata: Sendable, Equatable, Hashable {
    public let name: String
    public let description: String
    public let allowedTools: String?
    public let disableModelInvocation: Bool

    public init(
        name: String,
        description: String,
        allowedTools: String? = nil,
        disableModelInvocation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.allowedTools = allowedTools
        self.disableModelInvocation = disableModelInvocation
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else {
            return false
        }

        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar.value == 45
        }
    }
}

public struct Skill: Identifiable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public var id: String { metadata.name }

    public let metadata: SkillMetadata
    public let instructions: String?
    public let filePath: String

    public var isFullyLoaded: Bool { instructions != nil }

    public init(metadata: SkillMetadata, instructions: String?, filePath: String) {
        self.metadata = metadata
        self.instructions = instructions
        self.filePath = filePath
    }

    public var description: String {
        "Skill(\(metadata.name), \(isFullyLoaded ? "loaded" : "metadata-only"))"
    }
}

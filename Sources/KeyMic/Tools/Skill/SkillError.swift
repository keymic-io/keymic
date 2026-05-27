import Foundation

public enum SkillError: Error, LocalizedError, Equatable {
    case skillFileNotFound(path: String)
    case skillFileUnreadable(path: String, underlying: String)
    case frontmatterMissing(path: String)
    case frontmatterMalformed(path: String, reason: String)
    case requiredFieldMissing(path: String, field: String)
    case invalidName(name: String, path: String)
    case unknownSkill(name: String)
    case skillDisabledForModel(name: String)
    case duplicateSkill(name: String)

    public var errorDescription: String? {
        switch self {
        case .skillFileNotFound(let path):
            return "Skill file not found at \(path)."
        case .skillFileUnreadable(let path, let underlying):
            return "Skill file at \(path) could not be read: \(underlying)."
        case .frontmatterMissing(let path):
            return "Skill file at \(path) is missing frontmatter."
        case .frontmatterMalformed(let path, let reason):
            return "Skill file at \(path) has malformed frontmatter: \(reason)."
        case .requiredFieldMissing(let path, let field):
            return "Skill file at \(path) is missing required field '\(field)'."
        case .invalidName(let name, let path):
            return "Skill file at \(path) has invalid skill name '\(name)'."
        case .unknownSkill(let name):
            return "Unknown skill '\(name)'."
        case .skillDisabledForModel(let name):
            return "Skill '\(name)' is disabled for model invocation."
        case .duplicateSkill(let name):
            return "Duplicate skill named '\(name)'."
        }
    }
}

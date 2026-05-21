import Foundation

/// Errors raised by `FileSystemActor` and file tools (Read/Write/Edit/MultiEdit).
public enum FileSystemError: Error, LocalizedError {
    case pathNotSafe(path: String)
    case fileNotFound(path: String)
    case fileTooLarge(size: Int64, limit: Int64)
    case contentTooLarge(size: Int64, limit: Int64)
    case binaryFileDetected
    case invalidEncoding
    case notADirectory(path: String)
    case notAFile(path: String)
    case permissionDenied(path: String)
    case operationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .pathNotSafe(let path):
            return "Path is not within working directory: \(path)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileTooLarge(let size, let limit):
            return "File too large: \(size) bytes (limit: \(limit) bytes)"
        case .contentTooLarge(let size, let limit):
            return "Content too large: \(size) bytes (limit: \(limit) bytes)"
        case .binaryFileDetected:
            return "Cannot process binary file as text"
        case .invalidEncoding:
            return "Invalid UTF-8 encoding"
        case .notADirectory(let path):
            return "Path is not a directory: \(path)"
        case .notAFile(let path):
            return "Path is not a file: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .operationFailed(let reason):
            return "Operation failed: \(reason)"
        }
    }
}

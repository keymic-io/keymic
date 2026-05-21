import Foundation

/// An actor that centralizes path resolution + file IO for the file tools
/// (Read/Write/Edit/MultiEdit). Each tool call constructs its own actor with
/// `context.workingDirectory` — the actor itself is per-call serialization;
/// nothing persists across calls.
///
/// Adapted from SwiftAgent (MIT). FM-specific annotations removed; type and
/// method shapes preserved so the diff is reviewable against the upstream.
public actor FileSystemActor {

    /// Maximum file size for read/write operations (1 MB).
    public static let maxFileSize: Int64 = 1024 * 1024

    public static let defaultEncoding: String.Encoding = .utf8

    private let workingDirectory: String

    public init(workingDirectory: String = FileManager.default.currentDirectoryPath) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Path resolution

    /// Expand `~`, resolve relative paths against `workingDirectory`, and
    /// standardize. Does NOT check for safety (use `isPathSafe`).
    public func normalizePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = URL(fileURLWithPath: workingDirectory)
                .appendingPathComponent(expanded).path
        }
        return URL(fileURLWithPath: absolute).standardized.path
    }

    /// Returns `true` iff `path` resolves to a location within (or equal to)
    /// `workingDirectory`. Resolves symlinks on both sides to prevent escape
    /// via a symlink that points outside the sandbox.
    public func isPathSafe(_ path: String) -> Bool {
        let pathURL = URL(fileURLWithPath: path)
        let workingDirURL = URL(fileURLWithPath: workingDirectory)
        let resolvedPath = pathURL.resolvingSymlinksInPath().standardized.path
        let resolvedWorking = workingDirURL.resolvingSymlinksInPath().standardized.path
        return resolvedPath.hasPrefix(resolvedWorking + "/") || resolvedPath == resolvedWorking
    }

    // MARK: - Existence

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func fileExists(atPath path: String, isDirectory: inout ObjCBool) -> Bool {
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    // MARK: - Attributes

    public func fileAttributes(atPath path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }

    public func fileSize(atPath path: String) throws -> Int64? {
        try fileAttributes(atPath: path)[.size] as? Int64
    }

    /// Returns `true` if the data looks binary (contains a null byte or a
    /// control byte other than tab / LF / CR).
    public func isBinaryData(_ data: Data) -> Bool {
        let sampleSize = min(data.count, 1024)
        let sample = data.prefix(sampleSize)
        return sample.contains { byte in
            byte == 0 || (byte < 32 && byte != 9 && byte != 10 && byte != 13)
        }
    }

    // MARK: - Directory ops

    public func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public func listDirectory(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    // MARK: - File IO

    /// Reads a file as UTF-8 text. Enforces `maxFileSize` and rejects binary
    /// data.
    public func readFile(atPath path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.count > Self.maxFileSize {
            throw FileSystemError.fileTooLarge(size: Int64(data.count), limit: Self.maxFileSize)
        }
        if isBinaryData(data) {
            throw FileSystemError.binaryFileDetected
        }
        guard let content = String(data: data, encoding: Self.defaultEncoding) else {
            throw FileSystemError.invalidEncoding
        }
        return content
    }

    /// Writes `content` atomically. Creates parent directories if missing.
    /// Enforces `maxFileSize` on the encoded payload.
    public func writeFile(content: String, toPath path: String) throws {
        guard let data = content.data(using: Self.defaultEncoding) else {
            throw FileSystemError.invalidEncoding
        }
        if data.count > Self.maxFileSize {
            throw FileSystemError.contentTooLarge(size: Int64(data.count), limit: Self.maxFileSize)
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        if !directory.isEmpty && !fileExists(atPath: directory) {
            try createDirectory(atPath: directory)
        }
        try data.write(to: url, options: .atomic)
    }
}

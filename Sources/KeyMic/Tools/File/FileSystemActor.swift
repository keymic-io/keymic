import Foundation

/// An actor that centralizes path resolution + file IO for the file tools
/// (Read/Write/Edit/MultiEdit). Each tool call constructs its own actor with
/// `context.workingDirectory` — the actor itself provides per-instance
/// serialization; nothing persists across calls.
///
/// Why `actor` and not `struct`: the actor wrapper anticipates per-instance
/// mutable state in future plans (e.g. an open-file cache for MultiEdit
/// performance, or a write log for skill-scoped audit trails). It also keeps
/// the API uniformly `async`, which composes naturally with the rest of the
/// tool layer.
///
/// Blocking syscalls (`Data(contentsOf:)`, `Data.write(to:options:)`) are
/// dispatched to a global queue via `withCheckedThrowingContinuation` so they
/// do not stall the actor's cooperative-pool thread.
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
    ///
    /// `URL.resolvingSymlinksInPath()` only resolves symlinks for paths that
    /// exist on disk; for not-yet-created paths (e.g. a `writeFile` target)
    /// it silently no-ops. To close that hole we walk up the path to the
    /// deepest existing ancestor, resolve symlinks there, then re-append the
    /// non-existent tail.
    public func isPathSafe(_ path: String) -> Bool {
        let resolvedPath = Self.resolveSymlinksTolerantOfMissingTail(path)
        let resolvedWorking = URL(fileURLWithPath: workingDirectory)
            .resolvingSymlinksInPath().standardized.path
        return resolvedPath.hasPrefix(resolvedWorking + "/") || resolvedPath == resolvedWorking
    }

    /// Resolve symlinks even when the leaf (and possibly several leaves)
    /// don't exist yet. Walks up the path until we hit an existing ancestor,
    /// resolves symlinks on that ancestor, then re-attaches the non-existent
    /// tail components.
    private static func resolveSymlinksTolerantOfMissingTail(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardized.path
        var components = (standardized as NSString).pathComponents
        var tail: [String] = []
        let fm = FileManager.default
        while components.count > 1 {
            let candidate = NSString.path(withComponents: components)
            if fm.fileExists(atPath: candidate) {
                let resolved = URL(fileURLWithPath: candidate)
                    .resolvingSymlinksInPath().standardized.path
                if tail.isEmpty { return resolved }
                return (resolved as NSString)
                    .appendingPathComponent(NSString.path(withComponents: tail))
            }
            tail.insert(components.removeLast(), at: 0)
        }
        return standardized
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
    /// control byte other than tab / LF / CR). Pure function — exposed as
    /// `static` so it can be called from off-actor contexts (e.g. inside the
    /// global-queue dispatch in `readFile`).
    public static func isBinaryData(_ data: Data) -> Bool {
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
    /// data. The blocking IO portion is dispatched to a global queue so
    /// awaiting from `@MainActor` (or anywhere else on the cooperative pool)
    /// does not block the caller's executor.
    public func readFile(atPath path: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    if data.count > Self.maxFileSize {
                        continuation.resume(throwing: FileSystemError.fileTooLarge(
                            size: Int64(data.count), limit: Self.maxFileSize
                        ))
                        return
                    }
                    if FileSystemActor.isBinaryData(data) {
                        continuation.resume(throwing: FileSystemError.binaryFileDetected)
                        return
                    }
                    guard let content = String(data: data, encoding: Self.defaultEncoding) else {
                        continuation.resume(throwing: FileSystemError.invalidEncoding)
                        return
                    }
                    continuation.resume(returning: content)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Writes `content` atomically. Creates parent directories if missing.
    /// Enforces `maxFileSize` on the encoded payload. The blocking IO is
    /// dispatched to a global queue (see `readFile` rationale).
    public func writeFile(content: String, toPath path: String) async throws {
        guard let data = content.data(using: Self.defaultEncoding) else {
            throw FileSystemError.invalidEncoding
        }
        if data.count > Self.maxFileSize {
            throw FileSystemError.contentTooLarge(size: Int64(data.count), limit: Self.maxFileSize)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = URL(fileURLWithPath: path)
                    let directory = url.deletingLastPathComponent().path
                    if !directory.isEmpty,
                       !FileManager.default.fileExists(atPath: directory) {
                        try FileManager.default.createDirectory(
                            atPath: directory,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )
                    }
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

import CryptoKit
import Foundation
import OSLog
import SwiftData

@MainActor
final class ClipboardStore {
    private let container: ModelContainer
    private let context: ModelContext
    private(set) var maxHistory: Int
    private let cacheDirectory: URL

    private let cleanupModeProvider: () -> CleanupMode
    private let cleanupDaysProvider: () -> Int
    private let cleanupHook: (() -> Void)?
    private let kindClassifier: (String) -> ClipboardKind

    private var addCount: Int = 0
    var insertHook: ((ClipboardItem) -> Void)?

    // `nonisolated` so `prepareImage` (which runs off the main actor) can log too;
    // the static is immutable and `Logger` is Sendable, so this is safe.
    nonisolated private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardStore")

    /// Single-image size cap. Pasteboard payloads above this are dropped entirely.
    nonisolated static let maxImageBytes: Int = 20 * 1024 * 1024

    var clipboardCacheURL: URL { cacheDirectory }

    init(
        container: ModelContainer,
        maxHistory: Int,
        cacheDirectory: URL = ClipboardStore.defaultCacheURL(),
        cleanupModeProvider: @escaping () -> CleanupMode = { ClipboardPreferences.cleanupMode },
        cleanupDaysProvider: @escaping () -> Int = { ClipboardPreferences.cleanupDays },
        cleanupHook: (() -> Void)? = nil,
        kindClassifier: @escaping (String) -> ClipboardKind = { KindClassifier.shared.classify($0) }
    ) {
        self.container = container
        self.context = container.mainContext
        self.maxHistory = maxHistory
        self.cacheDirectory = cacheDirectory
        self.cleanupModeProvider = cleanupModeProvider
        self.cleanupDaysProvider = cleanupDaysProvider
        self.cleanupHook = cleanupHook
        self.kindClassifier = kindClassifier
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.addCount = fetchAll().count
        applyCleanup()
    }

    static func defaultStoreURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("KeyMic", isDirectory: true)
            .appendingPathComponent("Clipboard.store")
    }

    nonisolated static func defaultCacheURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("KeyMic", isDirectory: true)
            .appendingPathComponent("Clipboard.cache", isDirectory: true)
    }

    static func makeDefault(maxHistory: Int) -> ClipboardStore {
        do {
            let storeURL = defaultStoreURL()
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: ClipboardItem.self, VaultItem.self, configurations: config)
            return ClipboardStore(container: container, maxHistory: maxHistory, cacheDirectory: defaultCacheURL())
        } catch {
            logger.error(
                "ModelContainer init failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)"
            )
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: ClipboardItem.self, VaultItem.self, configurations: config)
            return ClipboardStore(container: container, maxHistory: maxHistory, cacheDirectory: defaultCacheURL())
        }
    }

    func fetchAll() -> [ClipboardItem] {
        let descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Returns the most recent `limit` clipboard texts in descending chronological order,
    /// non-empty after trimming. Used by `PersonaContextBuilder` to populate
    /// `PersonaContext.clipboardHistory` for personas that declare `.clipboardHistory`.
    func recentTexts(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let items = (try? context.fetch(descriptor)) ?? []
        return items.compactMap {
            let trimmed = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func add(text: String, sourceBundleID: String?, sourceAppName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Dedup on the *raw* text — the same canonical form that is stored. Looking up
        // a trimmed variant while storing raw made "hello\n" / "hello" bump each other
        // and let true duplicates accumulate. (add(richText:) dedups on raw too.)
        if let existing = findExisting(text: text) {
            let previousDate = existing.createdAt
            existing.createdAt = Date()
            if !saveDedup(newest: existing) {
                existing.createdAt = previousDate
            }
            return
        }

        let kind = kindClassifier(text)
        let item = ClipboardItem(
            text: text,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            kind: kind
        )
        context.insert(item)
        guard saveInserted(text: text) else {
            context.delete(item)
            return
        }
        finalizeInsert(item)
    }

    private func finalizeInsert(_ item: ClipboardItem) {
        insertHook?(item)
        if cleanupModeProvider() == .count {
            truncate(to: maxHistory)
        }
        addCount += 1
        if addCount % 10 == 0 {
            applyCleanup()
        }
    }

    /// Output of the main-thread-free image preparation phase. `Sendable` so it can
    /// hop from a background task back to the main actor for the SwiftData commit.
    struct PreparedImage: Sendable {
        let id: UUID
        let filename: String
        let hash: String
        let width: Int
        let height: Int
        let byteSize: Int
    }

    /// CPU/IO-heavy phase that touches NO SwiftData: hash the bytes and write the blob
    /// to the cache dir. `nonisolated` so callers can run it off the main thread — a
    /// 20 MB SHA-256 + atomic write on main would stall the run loop that also drives
    /// the `CGEvent` tap, briefly dropping every global hotkey. Returns nil if the
    /// data is oversized or the write fails.
    nonisolated func prepareImage(
        data: Data,
        format: ImageFormat,
        width: Int,
        height: Int
    ) -> PreparedImage? {
        guard data.count <= Self.maxImageBytes else {
            Self.logger.warning("prepareImage skip oversized bytes=\(data.count, privacy: .public)")
            return nil
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let filename = "\(id.uuidString).\(format.fileExtension)"
        let target = cacheDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            Self.logger.error("prepareImage write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return PreparedImage(id: id, filename: filename, hash: hash, width: width, height: height, byteSize: data.count)
    }

    /// Main-actor commit of a `PreparedImage`: dedup by contentHash (discarding the
    /// freshly-written file on a hit) then insert + save.
    func commitImage(_ prepared: PreparedImage, sourceBundleID: String?, sourceAppName: String?) {
        // Dedup by contentHash — bump createdAt, reuse the existing cache file, and
        // drop the redundant file prepareImage just wrote.
        if let existing = findExistingImage(hash: prepared.hash) {
            existing.createdAt = Date()
            try? context.save()
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(prepared.filename))
            return
        }

        let item = ClipboardItem(
            text: "Image \(prepared.width)×\(prepared.height)",
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            kind: .image
        )
        item.id = prepared.id
        item.imageRelativePath = prepared.filename
        item.imageWidth = prepared.width
        item.imageHeight = prepared.height
        item.byteSize = prepared.byteSize
        item.contentHash = prepared.hash
        context.insert(item)
        do {
            try context.save()
        } catch {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(prepared.filename))
            context.delete(item)
            Self.logger.error("commitImage save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        finalizeInsert(item)
    }

    /// Synchronous convenience used by tests and any non-hot-path caller: prepare +
    /// commit on the current (main) actor. The ⌥V capture path uses the split
    /// `prepareImage` (off-main) + `commitImage` (main) instead — see ClipboardMonitor.
    func add(
        image data: Data,
        format: ImageFormat,
        width: Int,
        height: Int,
        sourceBundleID: String?,
        sourceAppName: String?
    ) {
        guard let prepared = prepareImage(data: data, format: format, width: width, height: height) else { return }
        commitImage(prepared, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
    }

    private func findExistingImage(hash: String) -> ClipboardItem? {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        return try? context.fetch(descriptor).first
    }

    func add(
        fileURL: URL,
        sourceBundleID: String?,
        sourceAppName: String?
    ) {
        let path = fileURL.path
        guard !path.isEmpty else { return }

        if let existing = findExistingFile(path: path) {
            existing.createdAt = Date()
            try? context.save()
            return
        }

        let item = ClipboardItem(
            text: path,  // path is the searchable representation
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            kind: .file
        )
        item.fileURLPath = path
        context.insert(item)
        do { try context.save() } catch {
            context.delete(item)
            Self.logger.error("add(fileURL:) save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        finalizeInsert(item)
    }

    private func findExistingFile(path: String) -> ClipboardItem? {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.fileURLPath == path }
        )
        return try? context.fetch(descriptor).first
    }

    func add(
        richText blob: Data,
        format: RichTextFormat,
        plainText: String,
        sourceBundleID: String?,
        sourceAppName: String?
    ) {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let existing = findExisting(text: plainText) {
            // Bump createdAt; preserve whichever blob the existing row already holds.
            existing.createdAt = Date()
            try? context.save()
            return
        }

        let item = ClipboardItem(
            text: plainText,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            kind: .richText
        )
        item.richBlob = blob
        item.richBlobFormat = format
        item.byteSize = blob.count
        context.insert(item)
        do { try context.save() } catch {
            context.delete(item)
            Self.logger.error("add(richText:) save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        finalizeInsert(item)
    }

    func delete(id: UUID) {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.id == id }
        )
        guard let item = try? context.fetch(descriptor).first else { return }
        removeImageCacheFile(for: item)
        context.delete(item)
        try? context.save()
    }

    private func removeImageCacheFile(for item: ClipboardItem) {
        guard let rel = item.imageRelativePath, !rel.isEmpty else { return }
        let url = cacheDirectory.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every ClipboardItem row. Does NOT touch other model types in
    /// the same container (VaultItem is shared with this store).
    func deleteAllClipboardItems() {
        let descriptor = FetchDescriptor<ClipboardItem>()
        guard let all = try? context.fetch(descriptor) else { return }
        for item in all {
            removeImageCacheFile(for: item)
            context.delete(item)
        }
        try? context.save()
        addCount = 0
        Self.logger.info("deleteAllClipboardItems — removed \(all.count, privacy: .public) rows")
    }

    /// O(1)-ish SwiftData lookup by id. Resolves selection-bridge UUIDs back into
    /// `ClipboardItem` instances (e.g. for ordered multi-item paste).
    func item(id: UUID) -> ClipboardItem? {
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func bumpToTop(id: UUID) {
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        guard let item = try? context.fetch(descriptor).first else { return }
        item.createdAt = Date()
        try? context.save()
    }

    func togglePin(id: UUID) {
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        guard let item = try? context.fetch(descriptor).first else { return }
        item.isPinned.toggle()
        item.pinnedAt = item.isPinned ? Date() : nil
        try? context.save()
    }

    func installInsertHook(_ hook: @escaping (ClipboardItem) -> Void) {
        self.insertHook = hook
    }

    func updateMaxHistory(_ value: Int) {
        maxHistory = value
    }

    func truncate(to limit: Int) {
        maxHistory = limit
        let allUnpinned = fetchAll().filter { !$0.isPinned }
        guard allUnpinned.count > limit else { return }
        for item in allUnpinned[limit...] {
            removeImageCacheFile(for: item)
            context.delete(item)
        }
        try? context.save()
    }

    func applyCleanup() {
        cleanupHook?()
        switch cleanupModeProvider() {
        case .count:
            truncate(to: maxHistory)
        case .days:
            deleteOlderThan(days: cleanupDaysProvider())
        }
    }

    /// Scans `cacheDirectory` and deletes any file whose name does not match an
    /// `imageRelativePath` referenced by a live ClipboardItem. Called on app boot
    /// after the schema-version wipe.
    func collectOrphanCacheFiles() {
        let referenced: Set<String> = {
            let descriptor = FetchDescriptor<ClipboardItem>()
            let all = (try? context.fetch(descriptor)) ?? []
            return Set(all.compactMap { $0.imageRelativePath })
        }()

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        var removed = 0
        for entry in entries {
            if !referenced.contains(entry.lastPathComponent) {
                try? fm.removeItem(at: entry)
                removed += 1
            }
        }
        if removed > 0 {
            Self.logger.debug("collectOrphanCacheFiles — removed \(removed, privacy: .public) orphan files")
        }
    }

    // Intentionally case-sensitive: "Hello" and "hello" are distinct clipboard
    // entries even though the UI search is case-insensitive.
    private func findExisting(text: String) -> ClipboardItem? {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.text == text }
        )
        return try? context.fetch(descriptor).first
    }

    private func saveDedup(newest: ClipboardItem) -> Bool {
        do {
            try context.save()
            Self.logger.debug("dedup saved — newestLen=\(newest.text.count, privacy: .public)")
            return true
        } catch {
            Self.logger.error("dedup save failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func saveInserted(text: String) -> Bool {
        do {
            try context.save()
            Self.logger.debug("add saved — insertedLen=\(text.count, privacy: .public)")
            return true
        } catch {
            Self.logger.error("add save failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func deleteOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.createdAt < cutoff && $0.isPinned == false }
        )
        guard let stale = try? context.fetch(descriptor) else { return }
        for item in stale {
            removeImageCacheFile(for: item)
            context.delete(item)
        }
        try? context.save()
    }

    /// Test-only mirror of `deleteOlderThan(days:)`. Do not use from app code.
    func testDeleteOlderThan(days: Int) {
        deleteOlderThan(days: days)
    }

    var modelContainer: ModelContainer { container }
}

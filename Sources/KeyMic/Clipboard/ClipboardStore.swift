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

    private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardStore")

    /// Single-image size cap. Pasteboard payloads above this are dropped entirely.
    static let maxImageBytes: Int = 20 * 1024 * 1024

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

    func add(text: String, sourceBundleID: String?, sourceAppName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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
        insertHook?(item)

        if cleanupModeProvider() == .count {
            truncate(to: maxHistory)
        }

        addCount += 1
        if addCount % 10 == 0 {
            applyCleanup()
        }
    }

    func add(
        image data: Data,
        format: ImageFormat,
        width: Int,
        height: Int,
        sourceBundleID: String?,
        sourceAppName: String?
    ) {
        guard data.count <= Self.maxImageBytes else {
            Self.logger.info("add(image:) skip oversized bytes=\(data.count, privacy: .public)")
            return
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        // Dedup by contentHash — bump createdAt and reuse existing cache file.
        if let existing = findExistingImage(hash: hash) {
            existing.createdAt = Date()
            try? context.save()
            return
        }

        let id = UUID()
        let filename = "\(id.uuidString).\(format.fileExtension)"
        let target = cacheDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            Self.logger.error("add(image:) write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let item = ClipboardItem(
            text: "Image \(width)×\(height)",
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            kind: .image
        )
        item.id = id
        item.imageRelativePath = filename
        item.imageWidth = width
        item.imageHeight = height
        item.byteSize = data.count
        item.contentHash = hash
        context.insert(item)
        do {
            try context.save()
        } catch {
            try? FileManager.default.removeItem(at: target)
            context.delete(item)
            Self.logger.error("add(image:) save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        insertHook?(item)

        if cleanupModeProvider() == .count { truncate(to: maxHistory) }
        addCount += 1
        if addCount % 10 == 0 { applyCleanup() }
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
        insertHook?(item)

        if cleanupModeProvider() == .count { truncate(to: maxHistory) }
        addCount += 1
        if addCount % 10 == 0 { applyCleanup() }
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
        insertHook?(item)

        if cleanupModeProvider() == .count { truncate(to: maxHistory) }
        addCount += 1
        if addCount % 10 == 0 { applyCleanup() }
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
        Self.logger.info("deleteAllClipboardItems — removed \(all.count, privacy: .public) rows")
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
            Self.logger.info("collectOrphanCacheFiles — removed \(removed, privacy: .public) orphan files")
        }
    }

    private func findExisting(text: String) -> ClipboardItem? {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.text == text }
        )
        return try? context.fetch(descriptor).first
    }

    private func saveDedup(newest: ClipboardItem) -> Bool {
        do {
            try context.save()
            Self.logger.info(
                "dedup saved — count=\(self.fetchAll().count, privacy: .public) newestLen=\(newest.text.count, privacy: .public)"
            )
            return true
        } catch {
            Self.logger.error("dedup save failed — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func saveInserted(text: String) -> Bool {
        do {
            try context.save()
            let newest = fetchAll().first
            Self.logger.info(
                "add saved — count=\(self.fetchAll().count, privacy: .public) newestLen=\(newest?.text.count ?? -1, privacy: .public) newestMatches=\(newest?.text == text, privacy: .public)"
            )
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

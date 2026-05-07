import Foundation
import OSLog
import SwiftData

@MainActor
final class ClipboardStore {
    private let container: ModelContainer
    private let context: ModelContext
    private(set) var maxHistory: Int

    private let cleanupModeProvider: () -> CleanupMode
    private let cleanupDaysProvider: () -> Int
    private let cleanupHook: (() -> Void)?
    private let kindClassifier: (String) -> ClipboardKind

    private var addCount: Int = 0
    var insertHook: ((ClipboardItem) -> Void)?

    private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardStore")

    init(
        container: ModelContainer,
        maxHistory: Int,
        cleanupModeProvider: @escaping () -> CleanupMode = { ClipboardPreferences.cleanupMode },
        cleanupDaysProvider: @escaping () -> Int = { ClipboardPreferences.cleanupDays },
        cleanupHook: (() -> Void)? = nil,
        kindClassifier: @escaping (String) -> ClipboardKind = { KindClassifier.shared.classify($0) }
    ) {
        self.container = container
        self.context = container.mainContext
        self.maxHistory = maxHistory
        self.cleanupModeProvider = cleanupModeProvider
        self.cleanupDaysProvider = cleanupDaysProvider
        self.cleanupHook = cleanupHook
        self.kindClassifier = kindClassifier
        self.addCount = fetchAll().count
        applyCleanup()
    }

    static func defaultStoreURL(applicationSupportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("KeyMic", isDirectory: true)
            .appendingPathComponent("Clipboard.store")
    }

    static func makeDefault(maxHistory: Int) -> ClipboardStore {
        do {
            let storeURL = defaultStoreURL()
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: ClipboardItem.self, VaultItem.self, configurations: config)
            return ClipboardStore(container: container, maxHistory: maxHistory)
        } catch {
            logger.error("ModelContainer init failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)")
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: ClipboardItem.self, VaultItem.self, configurations: config)
            return ClipboardStore(container: container, maxHistory: maxHistory)
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

    func delete(id: UUID) {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.id == id }
        )
        guard let item = try? context.fetch(descriptor).first else { return }
        context.delete(item)
        try? context.save()
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

    private func findExisting(text: String) -> ClipboardItem? {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.text == text }
        )
        return try? context.fetch(descriptor).first
    }

    private func saveDedup(newest: ClipboardItem) -> Bool {
        do {
            try context.save()
            Self.logger.info("dedup saved — count=\(self.fetchAll().count, privacy: .public) newestLen=\(newest.text.count, privacy: .public)")
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
            Self.logger.info("add saved — count=\(self.fetchAll().count, privacy: .public) newestLen=\(newest?.text.count ?? -1, privacy: .public) newestMatches=\(newest?.text == text, privacy: .public)")
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
        for item in stale { context.delete(item) }
        try? context.save()
    }

    /// Test-only mirror of `deleteOlderThan(days:)`. Do not use from app code.
    func testDeleteOlderThan(days: Int) {
        deleteOlderThan(days: days)
    }

    var modelContainer: ModelContainer { container }
}

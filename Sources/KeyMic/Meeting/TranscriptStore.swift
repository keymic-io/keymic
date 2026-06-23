import Foundation
import OSLog
import SwiftData

@MainActor
final class TranscriptStore {
    private let container: ModelContainer
    private let context: ModelContext
    nonisolated private static let logger = Logger(subsystem: "io.keymic.app", category: "TranscriptStore")

    init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    static func defaultStoreURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("KeyMic", isDirectory: true)
            .appendingPathComponent("Meeting.store")
    }

    static func makeDefault() -> TranscriptStore {
        do {
            let storeURL = defaultStoreURL()
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: MeetingSession.self, TranscriptSegment.self, configurations: config)
            return TranscriptStore(container: container)
        } catch {
            logger.error("ModelContainer init failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)")
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try! ModelContainer(
                for: MeetingSession.self, TranscriptSegment.self, configurations: config)
            return TranscriptStore(container: container)
        }
    }

    /// Creates the in-progress session row immediately (endedAt nil). Returns its id.
    @discardableResult
    func startSession(localeCode: String, startedAt: Date = Date(), title: String? = nil) -> UUID {
        let session = MeetingSession(
            startedAt: startedAt,
            title: title ?? Self.defaultTitle(startedAt),
            localeCode: localeCode)
        context.insert(session)
        save("startSession")
        return session.id
    }

    /// Inserts one finalized segment, linked to its session. Called per endpoint.
    func appendFinalSegment(sessionID: UUID, offset: TimeInterval, text: String, source: Int) {
        guard let session = session(id: sessionID) else {
            Self.logger.error("appendFinalSegment: session \(sessionID.uuidString, privacy: .public) not found")
            return
        }
        let seg = TranscriptSegment(offset: offset, text: text, source: source, isFinal: true, session: session)
        context.insert(seg)
        save("appendFinalSegment")
    }

    func finishSession(_ id: UUID, endedAt: Date = Date()) {
        guard let s = session(id: id) else { return }
        s.endedAt = endedAt
        save("finishSession")
    }

    func allSessions() -> [MeetingSession] {
        let descriptor = FetchDescriptor<MeetingSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func segments(for sessionID: UUID) -> [TranscriptSegment] {
        let descriptor = FetchDescriptor<TranscriptSegment>(
            predicate: #Predicate { $0.session?.id == sessionID },
            sortBy: [SortDescriptor(\.offset, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func session(id: UUID) -> MeetingSession? {
        let descriptor = FetchDescriptor<MeetingSession>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func deleteSession(_ id: UUID) {
        guard let s = session(id: id) else { return }
        context.delete(s)   // cascade removes its segments
        save("deleteSession")
    }

    /// Remove every meeting session (and, by cascade, all their segments).
    func deleteAllSessions() {
        do {
            try context.delete(model: MeetingSession.self)
            save("deleteAllSessions")
        } catch {
            Self.logger.error("deleteAllSessions failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var modelContainer: ModelContainer { container }

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func save(_ op: String) {
        do { try context.save() }
        catch { Self.logger.error("\(op, privacy: .public) save failed: \(error.localizedDescription, privacy: .public)") }
    }
}

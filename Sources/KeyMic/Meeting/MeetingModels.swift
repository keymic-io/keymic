import Foundation
import SwiftData

/// One recorded meeting. `endedAt == nil` means in-progress, or — after a restart —
/// a session that was interrupted (crash / force-quit / sleep) and never finished.
/// Such sessions are kept and viewable, never resumed (PRD §4.6 crash recovery).
@Model
final class MeetingSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var title: String          // default = localized start-time string; rename deferred
    var localeCode: String     // recognition-language snapshot
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.session)
    var segments: [TranscriptSegment]

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        title: String,
        localeCode: String,
        segments: [TranscriptSegment] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.localeCode = localeCode
        self.segments = segments
    }
}

/// One finalized transcript line. `source`: 0 = me (mic), 1 = other (system audio).
/// `offset` = seconds since the owning session's `startedAt`.
@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var offset: TimeInterval
    var text: String
    var source: Int
    var isFinal: Bool
    var session: MeetingSession?

    init(
        id: UUID = UUID(),
        offset: TimeInterval,
        text: String,
        source: Int,
        isFinal: Bool = true,
        session: MeetingSession? = nil
    ) {
        self.id = id
        self.offset = offset
        self.text = text
        self.source = source
        self.isFinal = isFinal
        self.session = session
    }
}

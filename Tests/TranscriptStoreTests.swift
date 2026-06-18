import Foundation
import SwiftData

@main
struct TranscriptStoreTests {
    @MainActor
    static func main() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: MeetingSession.self, TranscriptSegment.self, configurations: config)
        let store = TranscriptStore(container: container)

        // start → session exists, endedAt nil (in-progress)
        let sid = store.startSession(localeCode: "zh-Hans", startedAt: Date(timeIntervalSince1970: 1000))
        let s0 = store.session(id: sid)
        assert(s0 != nil, "session should exist after startSession")
        assert(s0?.endedAt == nil, "new session endedAt must be nil")

        // append finals (out of order offsets) → stored, queryable in offset order, source preserved
        store.appendFinalSegment(sessionID: sid, offset: 2.0, text: "world", source: 1)
        store.appendFinalSegment(sessionID: sid, offset: 1.0, text: "hello", source: 0)
        let segs = store.segments(for: sid)
        assert(segs.count == 2, "expected 2 segments, got \(segs.count)")
        assert(segs.map(\.text) == ["hello", "world"], "segments must sort by offset asc: \(segs.map(\.text))")
        assert(segs[0].source == 0 && segs[1].source == 1, "source not preserved")
        assert(segs.allSatisfy { $0.isFinal }, "appended segments must be final")

        // finish → endedAt stamped
        store.finishSession(sid, endedAt: Date(timeIntervalSince1970: 2000))
        assert(store.session(id: sid)?.endedAt != nil, "finishSession must stamp endedAt")

        // a second, unfinished session simulates a crash-interrupted meeting (endedAt nil persists)
        let sid2 = store.startSession(localeCode: "en", startedAt: Date(timeIntervalSince1970: 3000))
        store.appendFinalSegment(sessionID: sid2, offset: 0.5, text: "partial work", source: 0)
        let interrupted = store.allSessions().first { $0.endedAt == nil }
        assert(interrupted?.id == sid2, "interrupted (endedAt nil) session must be retained")

        // allSessions sorted by startedAt desc (newest first)
        let all = store.allSessions()
        assert(all.count == 2, "expected 2 sessions, got \(all.count)")
        assert(all.first?.id == sid2, "allSessions must be newest-first")

        // delete cascades segments
        store.deleteSession(sid)
        assert(store.session(id: sid) == nil, "session should be gone after delete")
        assert(store.segments(for: sid).isEmpty, "segments must cascade-delete with session")

        print("TranscriptStoreTests passed")
    }
}

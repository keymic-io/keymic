import Foundation
import SwiftData

@main
struct MeetingControllerTests {
    @MainActor
    static func main() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: MeetingSession.self, TranscriptSegment.self, configurations: config)
        let store = TranscriptStore(container: container)

        var paused = 0, resumed = 0
        let c = MeetingController(
            store: store,
            onPauseVoice: { paused += 1 },
            onResumeVoice: { resumed += 1 },
            audioSourceProvider: { .both },
            localeProvider: { "zh-Hans" })

        assert(!c.isTranscribing, "starts idle")
        assert(c.currentOffset() == 0, "currentOffset must be 0 when idle (no startedAt)")

        // start → transcribing, session row created (endedAt nil), voice paused
        c.start()
        assert(c.isTranscribing, "start sets isTranscribing")
        assert(store.allSessions().count == 1, "start creates one session")
        assert(store.allSessions().first?.endedAt == nil, "session in-progress")
        assert(paused == 1 && resumed == 0, "start pauses voice once")
        assert(c.currentOffset() >= 0, "currentOffset must be >= 0 while transcribing")

        // double-start is idempotent (no second session, no extra pause)
        c.start()
        assert(store.allSessions().count == 1, "double-start must not create a second session")
        assert(paused == 1, "double-start must not re-pause")

        // stop → idle, session finished (endedAt set), voice resumed
        c.stop()
        assert(!c.isTranscribing, "stop clears isTranscribing")
        assert(store.allSessions().first?.endedAt != nil, "stop finishes the session")
        assert(resumed == 1, "stop resumes voice once")

        // double-stop is idempotent
        c.stop()
        assert(resumed == 1, "double-stop must not re-resume")

        // toggle flips
        c.toggle(); assert(c.isTranscribing, "toggle starts")
        c.toggle(); assert(!c.isTranscribing, "toggle stops")
        assert(store.allSessions().count == 2, "second start created a second session")

        // --- Prerequisite gate -------------------------------------------------
        // Fresh controller so the session counter is isolated from the cases above.
        var gPaused = 0
        let gated = MeetingController(
            store: store,
            onPauseVoice: { gPaused += 1 },
            onResumeVoice: {},
            audioSourceProvider: { .both },
            localeProvider: { "zh-Hans" })

        let baselineSessions = store.allSessions().count
        var missingFired = 0
        gated.prerequisitesReady = { false }
        gated.onPrerequisitesMissing = { missingFired += 1 }

        gated.start()
        assert(!gated.isTranscribing, "gate-fail must not enter transcribing state")
        assert(missingFired == 1, "gate-fail must fire onPrerequisitesMissing once")
        assert(gPaused == 0, "gate-fail must not pause voice")
        assert(store.allSessions().count == baselineSessions, "gate-fail must not create a session")

        // Now prerequisites pass → start proceeds normally.
        gated.prerequisitesReady = { true }
        gated.start()
        assert(gated.isTranscribing, "gate-pass starts the meeting")
        assert(missingFired == 1, "gate-pass must not fire onPrerequisitesMissing")
        assert(store.allSessions().count == baselineSessions + 1, "gate-pass creates a session")
        gated.stop()

        print("MeetingControllerTests passed")
    }
}

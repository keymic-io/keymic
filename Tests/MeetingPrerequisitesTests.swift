import Foundation

@main
struct MeetingPrerequisitesTests {
    static func main() {
        // modelReadyCombined requires BOTH runtime and model ready.
        assert(!MeetingPrerequisites(mic: .authorized, runtimeReady: false, modelReady: false).modelReadyCombined,
               "neither runtime nor model → model not ready")
        assert(!MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: false).modelReadyCombined,
               "runtime only → model not ready")
        assert(!MeetingPrerequisites(mic: .authorized, runtimeReady: false, modelReady: true).modelReadyCombined,
               "model only → model not ready")
        assert(MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: true).modelReadyCombined,
               "both → model ready")

        // allReady requires authorized mic AND modelReadyCombined.
        assert(MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: true).allReady,
               "all satisfied → allReady")
        assert(!MeetingPrerequisites(mic: .notDetermined, runtimeReady: true, modelReady: true).allReady,
               "notDetermined mic blocks allReady")
        assert(!MeetingPrerequisites(mic: .denied, runtimeReady: true, modelReady: true).allReady,
               "denied mic blocks allReady")
        assert(!MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: false).allReady,
               "missing model blocks allReady")
        assert(!MeetingPrerequisites(mic: .authorized, runtimeReady: false, modelReady: false).allReady,
               "missing runtime+model blocks allReady")

        // --- Screen Recording dimension (gated by requiresScreenRecording) ---------------
        // Not required → screenRecording is irrelevant.
        assert(MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: true,
                                    requiresScreenRecording: false, screenRecording: .denied).allReady,
               "screen recording not required → denied does not block")
        // Required + authorized → allReady.
        assert(MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: true,
                                    requiresScreenRecording: true, screenRecording: .authorized).allReady,
               "required + authorized → allReady")
        // Required + denied → blocked.
        assert(!MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: true,
                                     requiresScreenRecording: true, screenRecording: .denied).allReady,
               "required + denied → blocked")
        // Defaults (no screen-recording args) keep the original behavior.
        assert(MeetingPrerequisites(mic: .authorized, runtimeReady: true, modelReady: true).allReady,
               "default construction stays allReady when mic+model ready")

        print("MeetingPrerequisitesTests passed")
    }
}

import Foundation

/// Microphone authorization, reduced to the three states the setup UI cares about.
/// `.restricted` folds into `.denied` at the live-read site so this type stays AVFoundation-free
/// (and thus unit-testable without hardware). See `MeetingPrerequisites` for aggregation.
enum MicPermission {
    case authorized, notDetermined, denied
}

/// Screen Recording authorization, reduced to the two states the setup UI cares about. There is
/// no clean "notDetermined" via the CoreGraphics preflight API, so `false` folds into `.denied`
/// (the row then offers a request / System-Settings hand-off). Mapped at the live-read site.
enum ScreenRecordingPermission {
    case authorized, denied
}

/// Pure aggregation of the three meeting-start prerequisites into a single readiness verdict.
/// No UI / AVFoundation / AssetStore dependency — inputs are injected so tests cover every
/// combination. Production builds the live values via `MeetingPrerequisites.live()` (defined in
/// the AVFoundation-importing `MeetingSetupView.swift`, kept out of this file's test target).
struct MeetingPrerequisites {
    let mic: MicPermission
    let runtimeReady: Bool
    let modelReady: Bool
    /// Screen Recording is required only when the meeting captures system audio (`.both`/`.system`).
    /// Defaulted so existing call sites (mic-only / tests) construct unchanged.
    var requiresScreenRecording: Bool = false
    var screenRecording: ScreenRecordingPermission = .authorized

    /// Runtime + model are one concept to the user; both must be present.
    var modelReadyCombined: Bool { runtimeReady && modelReady }

    /// Every prerequisite satisfied — Start may proceed with no setup window.
    var allReady: Bool {
        mic == .authorized
            && modelReadyCombined
            && (!requiresScreenRecording || screenRecording == .authorized)
    }
}

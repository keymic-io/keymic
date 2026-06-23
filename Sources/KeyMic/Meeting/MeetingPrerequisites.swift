import Foundation

/// Microphone authorization, reduced to the three states the setup UI cares about.
/// `.restricted` folds into `.denied` at the live-read site so this type stays AVFoundation-free
/// (and thus unit-testable without hardware). See `MeetingPrerequisites` for aggregation.
enum MicPermission {
    case authorized, notDetermined, denied
}

/// Pure aggregation of the three meeting-start prerequisites into a single readiness verdict.
/// No UI / AVFoundation / AssetStore dependency — inputs are injected so tests cover every
/// combination. Production builds the live values via `MeetingPrerequisites.live()` (defined in
/// the AVFoundation-importing `MeetingSetupView.swift`, kept out of this file's test target).
struct MeetingPrerequisites {
    let mic: MicPermission
    let runtimeReady: Bool
    let modelReady: Bool

    /// Runtime + model are one concept to the user; both must be present.
    var modelReadyCombined: Bool { runtimeReady && modelReady }

    /// Every prerequisite satisfied — Start may proceed with no setup window.
    var allReady: Bool { mic == .authorized && modelReadyCombined }
}

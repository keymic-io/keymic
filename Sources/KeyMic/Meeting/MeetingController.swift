import Foundation
import Observation
import os

/// The real capture + ASR + caption pipeline, injected into `MeetingController`. Kept behind
/// a protocol so the controller's standalone test target needs no AVFoundation / AppKit /
/// CSherpaOnnx. Production conformer is `LiveMeetingPipeline`; tests inject nil (no-op hooks).
@MainActor
protocol MeetingPipeline: AnyObject {
    func start(session: UUID, source: MeetingAudioSource)
    func stop()
}

/// Lifecycle coordinator for meeting transcription. THIS IS THE SHELL: it owns start/stop
/// state, session persistence, the voice-input mutex, and delegates the audio capture +
/// streaming ASR + caption window to an injected `MeetingPipeline`. Mirrors the coordinator
/// role of `ClipboardController`.
@MainActor
@Observable
final class MeetingController {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "MeetingController")

    private(set) var isTranscribing = false

    @ObservationIgnored private let store: TranscriptStore
    @ObservationIgnored private let onPauseVoice: () -> Void
    @ObservationIgnored private let onResumeVoice: () -> Void
    @ObservationIgnored private let audioSourceProvider: () -> MeetingAudioSource
    @ObservationIgnored private let localeProvider: () -> String
    @ObservationIgnored private let pipeline: MeetingPipeline?

    /// Fired on every start/stop with the new `isTranscribing` value. Lets AppKit surfaces
    /// (e.g. the menu-bar item icon/title) refresh regardless of which path toggled the meeting.
    @ObservationIgnored var onTranscribingChanged: ((Bool) -> Void)?

    /// Returns whether Start may proceed. `nil` (default) → always proceed, so existing call
    /// sites and the standalone test target are unaffected. Injected by `AppDelegate` to evaluate
    /// `MeetingPrerequisites.live().allReady`.
    @ObservationIgnored var prerequisitesReady: (() -> Bool)?

    /// Fired when `start()` is blocked by a missing prerequisite. The host surfaces the guided
    /// setup window; the controller itself does NOT change state.
    @ObservationIgnored var onPrerequisitesMissing: (() -> Void)?

    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private(set) var startedAt: Date?

    init(
        store: TranscriptStore,
        onPauseVoice: @escaping () -> Void,
        onResumeVoice: @escaping () -> Void,
        audioSourceProvider: @escaping () -> MeetingAudioSource,
        localeProvider: @escaping () -> String,
        pipeline: MeetingPipeline? = nil
    ) {
        self.store = store
        self.onPauseVoice = onPauseVoice
        self.onResumeVoice = onResumeVoice
        self.audioSourceProvider = audioSourceProvider
        self.localeProvider = localeProvider
        self.pipeline = pipeline
    }

    func toggle() { isTranscribing ? stop() : start() }

    /// Begin a meeting. Idempotent if already transcribing. Prerequisite resolution
    /// (model download / permission, PRD §4.8) is enforced at this chokepoint via the injected
    /// `prerequisitesReady` closure; a missing prerequisite surfaces the guided setup window
    /// and returns without starting.
    func start() {
        guard !isTranscribing else { return }
        if let prerequisitesReady, !prerequisitesReady() {
            Self.logger.info("meeting start blocked: prerequisites missing")
            onPrerequisitesMissing?()
            return
        }
        let now = Date()
        let sid = store.startSession(localeCode: localeProvider(), startedAt: now)
        activeSessionID = sid
        startedAt = now
        isTranscribing = true
        onPauseVoice()   // mutex: pause push-to-talk while a meeting runs (PRD §4.1)
        startPipeline(session: sid, source: audioSourceProvider())
        onTranscribingChanged?(true)
        Self.logger.info("meeting started session=\(sid.uuidString, privacy: .public)")
    }

    /// End the active meeting. Idempotent if idle. Safe to call from sleep/lock handlers.
    func stop() {
        guard isTranscribing, let sid = activeSessionID else { return }
        stopPipeline()
        store.finishSession(sid)
        isTranscribing = false
        activeSessionID = nil
        startedAt = nil
        onResumeVoice()
        onTranscribingChanged?(false)
        Self.logger.info("meeting stopped session=\(sid.uuidString, privacy: .public)")
    }

    /// Seconds since the active session began — used by M3 to stamp segment offsets.
    func currentOffset(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    // MARK: - M3 pipeline hooks (delegated to the injected MeetingPipeline)

    /// Start mic capture + streaming ASR + caption window via the injected pipeline.
    /// No-op when no pipeline is injected (e.g. the controller's standalone test target).
    func startPipeline(session: UUID, source: MeetingAudioSource) {
        Self.logger.info("startPipeline source=\(source.rawValue, privacy: .public)")
        pipeline?.start(session: session, source: source)
    }

    /// Tear down capture + engine, hide the caption window.
    func stopPipeline() {
        Self.logger.info("stopPipeline")
        pipeline?.stop()
    }
}

/// Bridges the AppDelegate-owned controller/store to SwiftUI settings views, which are
/// constructed by SettingsRootView without injection. Set once at launch (Task 5).
@MainActor
final class MeetingRuntime {
    static let shared = MeetingRuntime()
    var controller: MeetingController?
    var store: TranscriptStore?
}

import Foundation
import Observation
import os

/// Lifecycle coordinator for meeting transcription. THIS IS THE SHELL: it owns start/stop
/// state, session persistence, the voice-input mutex, and exposes pipeline hooks. The actual
/// audio capture + streaming ASR + caption window are filled in by M3 via `startPipeline`/
/// `stopPipeline`. Mirrors the coordinator role of `ClipboardController`.
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

    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private(set) var startedAt: Date?

    init(
        store: TranscriptStore,
        onPauseVoice: @escaping () -> Void,
        onResumeVoice: @escaping () -> Void,
        audioSourceProvider: @escaping () -> MeetingAudioSource,
        localeProvider: @escaping () -> String
    ) {
        self.store = store
        self.onPauseVoice = onPauseVoice
        self.onResumeVoice = onResumeVoice
        self.audioSourceProvider = audioSourceProvider
        self.localeProvider = localeProvider
    }

    func toggle() { isTranscribing ? stop() : start() }

    /// Begin a meeting. Idempotent if already transcribing. Prerequisite resolution
    /// (model download / permission, PRD §4.8) is performed by the caller before invoking
    /// start() — the shell assumes prerequisites are met here.
    func start() {
        guard !isTranscribing else { return }
        let now = Date()
        let sid = store.startSession(localeCode: localeProvider(), startedAt: now)
        activeSessionID = sid
        startedAt = now
        isTranscribing = true
        onPauseVoice()   // mutex: pause push-to-talk while a meeting runs (PRD §4.1)
        startPipeline(session: sid, source: audioSourceProvider())
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
        Self.logger.info("meeting stopped session=\(sid.uuidString, privacy: .public)")
    }

    /// Seconds since the active session began — used by M3 to stamp segment offsets.
    func currentOffset(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    // MARK: - M3 fill-in hooks (shell defines no-ops; M3 implements the real pipeline)

    /// M3: start mic + system-audio capture, spin up per-channel StreamingASREngine, show caption window.
    func startPipeline(session: UUID, source: MeetingAudioSource) {
        Self.logger.info("startPipeline (M3 TODO) source=\(source.rawValue, privacy: .public)")
    }

    /// M3: tear down engines + capture, hide caption window.
    func stopPipeline() {
        Self.logger.info("stopPipeline (M3 TODO)")
    }
}

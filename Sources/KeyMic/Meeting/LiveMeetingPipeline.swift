import Foundation
import os

/// P2.1 production pipeline: one capture+engine pair per active `MeetingAudioSource` channel —
/// microphone (`source = 0`, "我") and/or system audio (`source = 1`, "对方"). Each engine has its
/// own `StreamingASRBridge` (one online stream per recognizer). The system channel additionally
/// feeds a `MeetingAudioRecorder` (16 kHz int16 WAV) that P2.2 diarizes offline. Captions are
/// source-labeled; `TranscriptStore` keeps RAW text + the source int. Owned by `AppDelegate`,
/// injected into `MeetingController`.
@MainActor
final class LiveMeetingPipeline: MeetingPipeline {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "LiveMeetingPipeline")
    private static let micSource = 0      // PRD "我"
    private static let systemSource = 1   // PRD "对方"
    private static let micLabel = String(localized: "我")
    private static let systemLabel = String(localized: "对方")

    private let store: TranscriptStore
    private let offsetProvider: () -> TimeInterval
    private let modelDirProvider: () -> URL
    private let onRequestStop: () -> Void

    private var sessionID: UUID?
    private var panel: MeetingCaptionPanel?

    private var micCapture: ContinuousMicCapture16k?
    private var micEngine: StreamingASREngine?

    private var systemCapture: SystemAudioCapture?
    private var systemEngine: StreamingASREngine?
    private var recorder: MeetingAudioRecorder?

    init(
        store: TranscriptStore,
        offsetProvider: @escaping () -> TimeInterval,
        modelDirProvider: @escaping () -> URL,
        onRequestStop: @escaping () -> Void
    ) {
        self.store = store
        self.offsetProvider = offsetProvider
        self.modelDirProvider = modelDirProvider
        self.onRequestStop = onRequestStop
    }

    func start(session: UUID, source: MeetingAudioSource) {
        sessionID = session

        let panel = MeetingCaptionPanel()
        panel.show()
        self.panel = panel

        let wantsMic = (source == .mic || source == .both)
        let wantsSystem = (source == .system || source == .both)

        if wantsMic, !startMic() { return }                      // mic failure is fatal when requested
        if wantsSystem { startSystem(session: session, degradeToMic: wantsMic) }
    }

    func stop() {
        micCapture?.stop()
        micEngine?.stop()

        // System capture stop is async; finalize the recorder only after it has stopped so no late
        // sample slips in past the WAV header patch.
        let cap = systemCapture
        let eng = systemEngine
        let rec = recorder
        eng?.stop()
        Task { await cap?.stop(); rec?.finish() }

        panel?.hide()

        micCapture = nil
        micEngine = nil
        systemCapture = nil
        systemEngine = nil
        recorder = nil
        panel = nil
        sessionID = nil
    }

    // MARK: - Channels

    /// Build an engine for `source`, wiring partial/final callbacks to the labeled caption and the
    /// raw-text store. Returns nil if the recognizer (model/runtime) is unavailable.
    private func makeEngine(source: Int) -> StreamingASREngine? {
        guard let bridge = StreamingASRBridge.create(modelDir: modelDirProvider()) else { return nil }
        let engine = StreamingASREngine(source: source, recognizer: bridge)
        engine.onPartial = { [weak self] src, text in
            guard let self else { return }
            self.panel?.updatePartial(self.labeled(src, text))
        }
        engine.onFinal = { [weak self] src, text in
            guard let self, let sid = self.sessionID else { return }
            self.panel?.appendFinal(self.labeled(src, text))
            self.store.appendFinalSegment(sessionID: sid, offset: self.offsetProvider(), text: text, source: src)
        }
        return engine
    }

    private func labeled(_ source: Int, _ text: String) -> String {
        let label = (source == Self.systemSource) ? Self.systemLabel : Self.micLabel
        return "\(label)：\(text)"
    }

    /// Returns false (and surfaces a fatal error) if the mic engine or device cannot start.
    private func startMic() -> Bool {
        guard let engine = makeEngine(source: Self.micSource) else {
            failFatal(String(localized: "Couldn't start transcription — model or runtime unavailable"))
            return false
        }
        micEngine = engine
        let mic = ContinuousMicCapture16k()
        mic.onSamples = { [weak engine] samples in engine?.feed(samples) }
        micCapture = mic
        do {
            try mic.start()
            return true
        } catch {
            Self.logger.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            failFatal(String(localized: "Couldn't start the microphone"))
            return false
        }
    }

    /// Start system-audio capture + engine + recorder. When `degradeToMic` is true (source `.both`)
    /// a failure logs and continues mic-only; otherwise it is fatal.
    private func startSystem(session: UUID, degradeToMic: Bool) {
        guard let engine = makeEngine(source: Self.systemSource) else {
            if degradeToMic {
                Self.logger.info("system engine create failed; continuing mic-only")
            } else {
                failFatal(String(localized: "Couldn't start transcription — model or runtime unavailable"))
            }
            return
        }
        systemEngine = engine

        let recorder = MeetingAudioRecorder(url: Self.audioURL(session))
        self.recorder = recorder

        let capture = SystemAudioCapture()
        capture.onSamples = { [weak engine, weak recorder] samples in
            engine?.feed(samples)
            recorder?.append(samples)
        }
        capture.onError = { [weak self] message in
            Task { @MainActor in
                Self.logger.error("system audio stream error: \(message, privacy: .public)")
                self?.panel?.showError(String(localized: "系统音频中断，仅继续转录麦克风"))
            }
        }
        systemCapture = capture

        Task { [weak self] in
            do {
                try await capture.start()
            } catch {
                await MainActor.run {
                    Self.logger.error("system audio start failed: \(error.localizedDescription, privacy: .public)")
                    if degradeToMic {
                        self?.panel?.showError(String(localized: "系统音频不可用，仅转录麦克风"))
                    } else {
                        self?.failFatal(String(localized: "Couldn't capture system audio"))
                    }
                }
            }
        }
    }

    private static func audioURL(_ session: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyMic/meeting-audio", isDirectory: true)
        return base.appendingPathComponent("\(session.uuidString).wav")
    }

    private func failFatal(_ message: String) {
        panel?.showError(message)
        requestStop()
    }

    /// Defer the stop so we never re-enter `MeetingController.start()` synchronously.
    private func requestStop() {
        let onRequestStop = self.onRequestStop
        DispatchQueue.main.async { onRequestStop() }
    }
}

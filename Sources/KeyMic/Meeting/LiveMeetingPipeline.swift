import Foundation
import os

/// M3.1 production pipeline: microphone → 16 kHz chunks → one `StreamingASREngine` →
/// caption window + persisted final segments. Single-source (mic, `source = 0`); system audio
/// and dual recognizers are M3.2. Owned by `AppDelegate`, injected into `MeetingController`.
@MainActor
final class LiveMeetingPipeline: MeetingPipeline {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "LiveMeetingPipeline")
    private static let micSource = 0   // PRD “我”

    private let store: TranscriptStore
    private let offsetProvider: () -> TimeInterval
    private let modelDirProvider: () -> URL
    private let onRequestStop: () -> Void

    private var sessionID: UUID?
    private var panel: MeetingCaptionPanel?
    private var mic: ContinuousMicCapture16k?
    private var engine: StreamingASREngine?

    /// - offsetProvider: seconds since the meeting began (`MeetingController.currentOffset()`).
    /// - modelDirProvider: streaming model directory (`OnnxStores.streaming.destDir`).
    /// - onRequestStop: called on a fatal pipeline error to stop the meeting via the normal
    ///   controller path (deferred to avoid re-entering `start()`).
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

        if source != .mic {
            // M3.1 is mic-only; system / both downgrade to mic. (M3.2 adds the second channel.)
            Self.logger.info("source \(source.rawValue, privacy: .public) → mic-only for M3.1")
        }

        guard let bridge = StreamingASRBridge.create(modelDir: modelDirProvider()) else {
            Self.logger.error("streaming recognizer creation failed")
            panel.showError(String(localized: "Couldn't start transcription — model or runtime unavailable"))
            requestStop()
            return
        }

        let engine = StreamingASREngine(source: Self.micSource, recognizer: bridge)
        engine.onPartial = { [weak self] _, text in
            self?.panel?.updatePartial(text)
        }
        engine.onFinal = { [weak self] source, text in
            guard let self, let sid = self.sessionID else { return }
            self.panel?.appendFinal(text)
            self.store.appendFinalSegment(
                sessionID: sid, offset: self.offsetProvider(), text: text, source: source)
        }
        self.engine = engine

        let mic = ContinuousMicCapture16k()
        mic.onSamples = { [weak engine] samples in engine?.feed(samples) }
        self.mic = mic

        do {
            try mic.start()
        } catch {
            Self.logger.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            panel.showError(String(localized: "Couldn't start the microphone"))
            requestStop()
        }
    }

    func stop() {
        mic?.stop()
        engine?.stop()
        panel?.hide()
        mic = nil
        engine = nil
        panel = nil
        sessionID = nil
    }

    /// Defer the stop so we never re-enter `MeetingController.start()` synchronously.
    private func requestStop() {
        let onRequestStop = self.onRequestStop
        DispatchQueue.main.async { onRequestStop() }
    }
}

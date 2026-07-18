import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SenseVoiceSpeechEngine")

/// Batch ASR engine backed by the SenseVoiceSmall CoreML model. Mirrors `AppleSpeechEngine`'s
/// session lifecycle (capture on hold, transcribe on release). The final transcript runs once on
/// `endAudio` (fbank → model → CTC-decode) and drives injection. For live preview, a 1s timer
/// (`partialTick`) re-decodes the growing buffer during the hold and emits `onPartialResult`
/// (overlay only) — pseudo-streaming, since the model itself is not streaming.
///
/// Intentionally NOT annotated `@available(macOS 15)`: see `SenseVoiceModel`. The model is only
/// constructed when `SenseVoiceModelStore.loadModel()` succeeds (macOS 15+), gated by the factory.
@MainActor
final class SenseVoiceSpeechEngine: SpeechEngineProtocol {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?
    /// SenseVoice selects language via an integer embedding id (set at init), not an
    /// `SFSpeechRecognizer` locale. Stored only to satisfy the protocol.
    var locale: Locale = Locale(identifier: "auto")

    private let capture = AudioCapture16k()
    private let fbank: FbankExtractor
    private let decoder: CTCDecoder
    private let model: SenseVoiceModel
    private let languageId: Int
    private let textnormId: Int
    /// Recreated on every `startSession()`: a long-lived AVAudioEngine caches the input
    /// device's HAL format, so after a default-input change (headset connect/disconnect,
    /// sample-rate switch) `start()` throws kAudioUnitErr_FormatNotSupported (-10868).
    /// A fresh engine rebinds to the current device — mirrors AppleSpeechEngine's
    /// per-session `audioEngineFactory`.
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    /// Fires every 1s during hold to emit live partials. Cancelled in `teardown()`.
    private var partialTimer: DispatchSourceTimer?
    /// Single-flight: skip a tick if the previous partial decode is still running,
    /// so slow decodes can't pile up. Main-actor only.
    private var isDecoding = false
    /// Bluetooth SCO cold start can leave the engine "running" with no frames
    /// arriving. Mirror AppleSpeechEngine's 800ms watchdog: no first buffer →
    /// tear down and surface an error instead of silently recording nothing.
    private var firstBufferReceived = false
    /// Session start timestamp, for the `engine_cold_start` first-buffer latency.
    private var sessionStartTime: DispatchTime?
    private var audioWatchdog: DispatchWorkItem?
    /// Bumped on every `startSession()`. A background final/partial decode captures the
    /// generation it was dispatched under and drops its result if a newer session has
    /// started in the meantime — otherwise utterance A's late final could be injected
    /// into utterance B (the callbacks are shared across sessions on this engine).
    /// Main-actor only.
    private var sessionGeneration = 0

    init(
        model: SenseVoiceModel, fbank: FbankExtractor, decoder: CTCDecoder,
        languageId: Int, textnormId: Int
    ) {
        self.model = model
        self.fbank = fbank
        self.decoder = decoder
        self.languageId = languageId
        self.textnormId = textnormId
        capture.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
    }

    func startSession() throws -> VoiceSession {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else { throw VoiceError.microphoneAccessDenied(status) }

        // Self-heal: a second entry point bypassing the session host may still have our
        // tap installed — installing twice throws an Obj-C NSException and crashes.
        // Mirror SpeechAnalyzerSpeechEngine.startSession.
        teardown()
        sessionGeneration &+= 1
        capture.reset()
        firstBufferReceived = false
        sessionStartTime = .now()
        engine = AVAudioEngine()  // rebind to the current default input device (see decl)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.capture.append(buf)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.firstBufferReceived else { return }
                self.firstBufferReceived = true
                self.audioWatchdog?.cancel(); self.audioWatchdog = nil
                let elapsedMs = self.sessionStartTime.map {
                    Int((DispatchTime.now().uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000)
                } ?? 0
                TelemetryService.shared.engineColdStart(
                    engine: "senseVoice", firstBufferMs: elapsedMs, scoWatchdogFired: false)
            }
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            logger.error("engine.start failed: \(error.localizedDescription, privacy: .public)")
            throw VoiceError.audioEngineFailed(error.localizedDescription)
        }
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        logger.debug("startSession — input device: \(deviceName, privacy: .public)")
        let myGen = sessionGeneration
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGeneration == myGen, !self.firstBufferReceived else { return }
            logger.error(
                "No audio frames in 800ms — Bluetooth SCO cold-start failure (device: \(deviceName, privacy: .public))")
            let elapsedMs = self.sessionStartTime.map {
                Int((DispatchTime.now().uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000)
            } ?? 0
            TelemetryService.shared.engineColdStart(
                engine: "senseVoice", firstBufferMs: elapsedMs, scoWatchdogFired: true)
            self.teardown()
            self.onError?("麦克风未响应，请松开后稍候再试")
        }
        audioWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: watchdog)
        // Pseudo-streaming: re-decode the growing buffer once per second. First fire at
        // +1s naturally implements the "<1s hold emits no partial" threshold.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.partialTick() }
        timer.resume()
        partialTimer = timer
        return VoiceSession { [weak self] in self?.teardown() }
    }

    /// fbank → model → CTC decode on a sample snapshot. `static` so it carries no
    /// `@MainActor` isolation and is safe to call from a background queue. Returns
    /// "" when the feature matrix is empty (silence / too-short audio).
    private static func runPipeline(
        samples: [Float], fbank: FbankExtractor, model: SenseVoiceModel,
        decoder: CTCDecoder, languageId: Int, textnormId: Int
    ) throws -> String {
        let feat = fbank.extract(samples: samples)
        guard !feat.isEmpty else { return "" }
        let logits = try model.infer(features: feat, languageId: languageId, textnormId: textnormId)
        return decoder.decode(logits: logits)
    }

    /// Release: stop capture, then transcribe the whole utterance off the main thread.
    /// `capture.snapshot()` is taken on the main thread AFTER `teardown()` cancels the
    /// partial timer and removes the tap. Final drives injection (state machine).
    func endAudio() {
        teardown()
        let samples = capture.snapshot()
        let fbank = self.fbank
        let model = self.model
        let decoder = self.decoder
        let lang = languageId
        let tnorm = textnormId
        let gen = sessionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let text = try Self.runPipeline(
                    samples: samples, fbank: fbank, model: model,
                    decoder: decoder, languageId: lang, textnormId: tnorm)
                DispatchQueue.main.async {
                    guard let self, gen == self.sessionGeneration else { return }
                    self.onFinalResult?(text)
                }
            } catch {
                let message = (error as? VoiceError)?.displayMessage ?? error.localizedDescription
                logger.error("final decode failed: \(message, privacy: .public)")
                DispatchQueue.main.async {
                    guard let self, gen == self.sessionGeneration else { return }
                    self.onError?(message)
                }
            }
        }
    }

    /// One partial pass: snapshot current audio, decode off-main, emit a partial.
    /// Drops the tick if a previous decode is in flight. Decode errors are logged
    /// and swallowed (never surfaced via onError) so partials don't disrupt capture.
    ///
    /// A partial dispatched just before `endAudio()` can finish AFTER the final
    /// result (both hop through `main.async`), so `onPartialResult` may fire with
    /// stale text post-final. That's harmless: `VoiceTrigger.finish()` releases its
    /// speech session before starting the LLM run, and `handlePartial`/`handleFinal`
    /// drop callbacks once the session is gone — final stays authoritative for the
    /// overlay/injection.
    /// Such a late partial also runs `runPipeline` concurrently with the final
    /// decode, i.e. two `model.infer` on the shared CoreML model; `MLModel`
    /// serializes concurrent predictions internally, so it's safe (transient 2x).
    private func partialTick() {
        if isDecoding { return }
        isDecoding = true
        let samples = capture.snapshot()
        let fbank = self.fbank
        let model = self.model
        let decoder = self.decoder
        let lang = languageId
        let tnorm = textnormId
        let gen = sessionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let text = try Self.runPipeline(
                    samples: samples, fbank: fbank, model: model,
                    decoder: decoder, languageId: lang, textnormId: tnorm)
                DispatchQueue.main.async {
                    self?.isDecoding = false
                    // Drop a partial from a session that has already been superseded.
                    guard let self, gen == self.sessionGeneration else { return }
                    // Empty result = silence / too-short; don't clear the overlay.
                    if !text.isEmpty { self.onPartialResult?(text) }
                }
            } catch {
                logger.debug("partial decode failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self?.isDecoding = false }
            }
        }
    }

    private func teardown() {
        audioWatchdog?.cancel()
        audioWatchdog = nil
        partialTimer?.cancel()
        partialTimer = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }
}

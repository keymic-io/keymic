import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SenseVoiceSpeechEngine")

/// Batch ASR engine backed by the SenseVoiceSmall CoreML model. Mirrors `AppleSpeechEngine`'s
/// session lifecycle (capture on hold, transcribe on release) but produces no partial results —
/// the whole utterance is captured, then fbank → model → CTC-decode runs once on `endAudio`.
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
    private let engine = AVAudioEngine()
    private var tapInstalled = false

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

        capture.reset()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.capture.append(buf)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw VoiceError.audioEngineFailed(error.localizedDescription)
        }
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        logger.info("startSession — input device: \(deviceName, privacy: .public)")
        return VoiceSession { [weak self] in self?.teardown() }
    }

    /// Release: stop capture, then transcribe the whole utterance off the main thread.
    /// No partials. `capture.samples` is snapshotted on the main thread (here) AFTER
    /// `teardown()` removes the tap, so the audio thread can no longer mutate it.
    func endAudio() {
        teardown()
        let samples = capture.samples
        // Capture the immutable collaborators by value so the background closure does not touch
        // `@MainActor` state. Callbacks hop back to main.
        let fbank = self.fbank
        let model = self.model
        let decoder = self.decoder
        let lang = languageId
        let tnorm = textnormId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text: String
            do {
                let feat = fbank.extract(samples: samples)
                guard !feat.isEmpty else {
                    DispatchQueue.main.async { self?.onFinalResult?("") }
                    return
                }
                let logits = try model.infer(features: feat, languageId: lang, textnormId: tnorm)
                text = decoder.decode(logits: logits)
            } catch {
                let message = (error as? VoiceError)?.displayMessage ?? error.localizedDescription
                DispatchQueue.main.async { self?.onError?(message) }
                return
            }
            DispatchQueue.main.async { self?.onFinalResult?(text) }
        }
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }
}

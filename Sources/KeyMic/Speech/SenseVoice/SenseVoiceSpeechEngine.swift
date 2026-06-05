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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let text = try Self.runPipeline(
                    samples: samples, fbank: fbank, model: model,
                    decoder: decoder, languageId: lang, textnormId: tnorm)
                DispatchQueue.main.async { self?.onFinalResult?(text) }
            } catch {
                let message = (error as? VoiceError)?.displayMessage ?? error.localizedDescription
                DispatchQueue.main.async { self?.onError?(message) }
            }
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

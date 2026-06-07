#if KEYMIC_HAS_SPEECH_ANALYZER
import AVFoundation
import Foundation
import Speech
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SpeechAnalyzerEngine")

/// Convert one mic buffer to the analyzer's format. Free function (no actor
/// isolation) so it is safe to call from the AVAudioEngine realtime thread.
@available(macOS 26, *)
private func convertBuffer(_ buffer: AVAudioPCMBuffer,
                           using converter: AVAudioConverter,
                           to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
    if let err { logger.error("convert failed: \(err.localizedDescription, privacy: .public)"); return nil }
    return out
}

/// macOS 26 SpeechAnalyzer-backed engine. Conforms to the same callback-based
/// `SpeechEngineProtocol` as AppleSpeechEngine so the rest of the app is agnostic.
/// Constructed only when SpeechAnalyzerSupport reports the locale supported AND
/// its asset installed (gating in AppDelegate), so `analyzerFormat` is non-nil.
@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerSpeechEngine: SpeechEngineProtocol {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?
    var locale: Locale

    private let analyzerFormat: AVAudioFormat
    private let microphoneAuthorizationProbe: () -> AVAuthorizationStatus

    private let engine = AVAudioEngine()
    private var inputTapInstalled = false
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?

    private var firstBufferReceived = false
    private var audioWatchdog: DispatchWorkItem?
    // Bumped on every startSession / endSession. Result + start callbacks capture
    // their own generation at creation and drop callbacks once the value diverges,
    // so a stale task can no longer pollute the live session.
    private var generation: UInt64 = 0

    init(locale: Locale,
         analyzerFormat: AVAudioFormat,
         microphoneAuthorizationProbe: @escaping () -> AVAuthorizationStatus = {
             AVCaptureDevice.authorizationStatus(for: .audio)
         }) {
        self.locale = locale
        self.analyzerFormat = analyzerFormat
        self.microphoneAuthorizationProbe = microphoneAuthorizationProbe
    }

    func startSession() throws -> VoiceSession {
        let status = microphoneAuthorizationProbe()
        guard status == .authorized else { throw VoiceError.microphoneAccessDenied(status) }

        teardownInternal()
        generation &+= 1
        let myGen = generation
        firstBufferReceived = false

        // `.progressiveTranscription` preset sets reportingOptions = [.volatileResults]
        // so we receive streaming partials (volatile) followed by a finalized result.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        // Consume transcription results. `result.isFinal` is a SpeechModuleResult
        // protocol-extension property; `result.text` is an AttributedString.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        guard let self, self.generation == myGen else { return }
                        if isFinal { self.onFinalResult?(text) } else { self.onPartialResult?(text) }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.generation == myGen else { return }
                    self.onError?(error.localizedDescription)
                }
            }
        }

        // Feed audio into the analyzer.
        let (audioStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        Task { [weak self] in
            do { try await analyzer.start(inputSequence: audioStream) }
            catch {
                await MainActor.run {
                    guard let self, self.generation == myGen else { return }
                    self.onError?(error.localizedDescription)
                }
            }
        }

        // Mic tap: RMS level + convert to analyzer format + yield.
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = analyzerFormat
        guard let sessionConverter = AVAudioConverter(from: micFormat, to: targetFormat) else {
            teardownInternal()
            throw VoiceError.audioEngineFailed("无法创建音频转换器")
        }
        converter = sessionConverter
        // Captured locals so the realtime audio thread never reads @MainActor
        // properties of `self` (which teardownInternal mutates on the main actor).
        let capturedConverter = sessionConverter
        let capturedContinuation = continuation
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        logger.debug("startSession — input device: \(deviceName, privacy: .public)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            // Audio level (RMS): compute on the audio thread, deliver on main.
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrtf(sum / Float(max(n, 1)))
                let dB = 20 * log10(max(rms, 1e-6))
                let norm = max(Float(0), min(Float(1), (dB + 50) / 40))
                DispatchQueue.main.async { [weak self] in self?.onAudioLevel?(norm) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.firstBufferReceived else { return }
                self.firstBufferReceived = true
                self.audioWatchdog?.cancel(); self.audioWatchdog = nil
            }
            if let converted = convertBuffer(buffer, using: capturedConverter, to: targetFormat) {
                capturedContinuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        inputTapInstalled = true

        engine.prepare()
        do { try engine.start() }
        catch {
            teardownInternal()
            throw VoiceError.audioEngineFailed(error.localizedDescription)
        }

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.generation == myGen, !self.firstBufferReceived else { return }
            logger.error("No audio frames in 800ms (device: \(deviceName, privacy: .public))")
            self.teardownInternal()
            self.onError?("麦克风未响应，请松开后稍候再试")
        }
        audioWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: watchdog)

        let sessionGen = myGen
        return VoiceSession { [weak self] in
            guard let self, self.generation == sessionGen else { return }
            self.endSession()
        }
    }

    /// Stop capture but let the transcriber drain to a final result.
    func endAudio() {
        teardownAudioOnly()
        inputContinuation?.finish()
        let a = analyzer
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
    }

    private func endSession() {
        generation &+= 1
        teardownInternal()
    }

    private func teardownAudioOnly() {
        audioWatchdog?.cancel(); audioWatchdog = nil
        if inputTapInstalled { engine.inputNode.removeTap(onBus: 0); inputTapInstalled = false }
        if engine.isRunning { engine.stop() }
    }

    private func teardownInternal() {
        teardownAudioOnly()
        resultsTask?.cancel(); resultsTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        analyzer = nil
        transcriber = nil
        converter = nil
    }
}
#endif

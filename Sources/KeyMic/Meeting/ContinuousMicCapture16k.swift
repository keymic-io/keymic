import AVFoundation
import os.log

/// Continuous microphone capture for meeting transcription: an `AVAudioEngine` input tap
/// converted to 16 kHz mono `Float` chunks, emitted through `onSamples`. Unlike
/// `AudioCapture16k` (push-to-talk, accumulates a whole utterance for batch ASR), this
/// retains no audio — each tap buffer is resampled and handed off immediately. Keeping it
/// separate avoids regressing the voice-input path. NOT for batch use.
final class ContinuousMicCapture16k {
    /// Called on the audio tap thread with each 16 kHz mono `Float` chunk. Forward to a
    /// serial ASR queue (e.g. `StreamingASREngine.feed`); do not do heavy work here.
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let resampler = PCMResampler16k()
    private var running = false
    private static let logger = Logger(subsystem: "io.keymic.app", category: "ContinuousMicCapture16k")

    /// Install the tap and start the engine. Idempotent. Throws if the engine fails to start.
    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        Self.logger.info("start — input device: \(deviceName, privacy: .public)")

        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.resample(buffer)
            guard !samples.isEmpty else { return }
            self.onSamples?(samples)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            Self.logger.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        running = true
    }

    /// Stop the engine and remove the tap. Idempotent.
    func stop() {
        guard running else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }
}

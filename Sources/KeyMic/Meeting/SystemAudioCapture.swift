import AVFoundation
import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SystemAudioCapture")

/// Captures system audio output via an audio-only ScreenCaptureKit SCStream, resampled to
/// 16 kHz mono Float32. Requires Screen Recording permission. Excludes KeyMic's own audio.
/// `onSamples` fires on the capture queue — hop to your own queue before touching ASR state.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: Error { case permissionDenied, noDisplay, streamFailed(String) }

    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let resampler = PCMResampler16k()
    private let queue = DispatchQueue(label: "io.keymic.app.systemaudio")

    func start() async throws {
        let content: SCShareableContent
        do {
            // Triggers / verifies the Screen Recording TCC grant, same as ScreenCapturer.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("SCShareableContent failed (permission?): \(error.localizedDescription, privacy: .public)")
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // Audio capture still requires a content filter; a display filter captures system-wide audio.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // keep KeyMic's own sounds out of "other party"
        config.sampleRate = 16000                    // request our target; we still resample defensively
        config.channelCount = 1
        // Minimize video work — we only want audio, but a stream needs a video config too.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
        logger.info("system audio capture started")
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        logger.info("system audio capture stopped")
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.resample(pcm)
        if !samples.isEmpty { onSamples?(samples) }
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("stream stopped with error: \(error.localizedDescription, privacy: .public)")
        onError?(error.localizedDescription)
    }

    /// Turn an audio CMSampleBuffer into an AVAudioPCMBuffer using its own format description.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        var asbdCopy = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

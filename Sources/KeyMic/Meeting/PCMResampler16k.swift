import AVFoundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "PCMResampler16k")

/// Converts an arbitrary-format `AVAudioPCMBuffer` to 16 kHz mono Float32 samples.
/// Pure `AVAudioConverter` — no `AVAudioEngine`, no accumulation. One instance per source
/// (the converter caches the input→output format pair). NOT thread-safe; call from one queue.
final class PCMResampler16k {
    static let targetSampleRate: Double = 16000

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: PCMResampler16k.targetSampleRate,
        channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Returns 16k mono Float32 samples, or [] on converter failure.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if converter == nil || sourceFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                logger.error("AVAudioConverter init failed")
                return []
            }
            converter = c
            sourceFormat = buffer.format
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return [] }
        var fed = false
        var err: NSError?
        converter?.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if let err { logger.error("convert error: \(err.localizedDescription, privacy: .public)"); return [] }
        guard let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}

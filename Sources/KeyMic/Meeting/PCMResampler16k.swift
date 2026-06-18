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
        guard let conv = converter else { return [] }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        // Use a per-chunk output capacity; we loop until the converter signals endOfStream.
        let chunkCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 256)

        var samples: [Float] = []
        samples.reserveCapacity(Int(chunkCap))

        // Track whether the input buffer has been fed to the converter yet.
        // On the first pull we return the buffer; on subsequent pulls we signal
        // endOfStream so the converter flushes its polyphase-filter tail fully.
        var fed = false

        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkCap) else { break }
            var err: NSError?
            let status = conv.convert(to: chunk, error: &err) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let err {
                logger.error("convert error: \(err.localizedDescription, privacy: .public)")
                return []
            }
            if chunk.frameLength > 0, let ch = chunk.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(chunk.frameLength)))
            }
            // Stop when the converter has flushed everything.
            if status == .endOfStream || status == .error || chunk.frameLength == 0 {
                break
            }
        }

        return samples
    }
}

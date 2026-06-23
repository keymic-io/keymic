import AVFoundation
import Foundation

@main
struct PCMResampler16kTests {
    static func main() {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 48000, channels: 2, interleaved: false)!
        let frames: AVAudioFrameCount = 24000  // 0.5s @ 48k
        let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        buf.frameLength = frames
        // Fill both channels with a 440 Hz sine so RMS is clearly non-zero.
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0)
            }
        }

        let resampler = PCMResampler16k()
        let out = resampler.resample(buf)

        // 0.5s @ 16k = 8000 samples; full drain via endOfStream flush.
        assert(out.count > 7600 && out.count < 8400, "unexpected resampled count: \(out.count)")
        let rms = sqrtf(out.reduce(0) { $0 + $1 * $1 } / Float(max(out.count, 1)))
        assert(rms > 0.1, "resampled signal should be non-silent, rms=\(rms)")

        // Reuse across buffers (continuous capture): the SAME instance must keep producing
        // output for every subsequent buffer — not just the first. Regression guard for the
        // AVAudioConverter endOfStream-is-terminal bug that broke meeting transcription.
        let out2 = resampler.resample(buf)
        assert(out2.count > 7600 && out2.count < 8400, "2nd resample on reused instance returned \(out2.count) (converter left in terminal state?)")
        let out3 = resampler.resample(buf)
        assert(out3.count > 7600 && out3.count < 8400, "3rd resample on reused instance returned \(out3.count)")

        print("PCMResampler16kTests passed")
    }
}

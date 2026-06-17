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

        // 0.5s @ 16k ≈ 8000 samples; allow converter edge slack.
        assert(out.count > 6400 && out.count < 8400, "unexpected resampled count: \(out.count)")
        let rms = sqrtf(out.reduce(0) { $0 + $1 * $1 } / Float(max(out.count, 1)))
        assert(rms > 0.1, "resampled signal should be non-silent, rms=\(rms)")
        print("PCMResampler16kTests passed")
    }
}

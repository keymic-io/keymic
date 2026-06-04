import AVFoundation

@main
struct AudioCapture16kTestRunner {
    static func main() {
        // already-16k buffer: accumulate directly (no resampling needed)
        let cap = AudioCapture16k()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000)!
        buf.frameLength = 16000
        let level = cap.accumulate(buf)
        precondition(cap.samples.count == 16000, "should accumulate 16000 samples (\(cap.samples.count))")
        precondition(level >= 0 && level <= 1, "level normalized 0..1 (\(level))")

        // resampling: 48k mono → expect ~16000 (×1/3) appended via the real append() converter path
        let cap2 = AudioCapture16k()
        let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buf48 = AVAudioPCMBuffer(pcmFormat: fmt48, frameCapacity: 48000)!
        buf48.frameLength = 48000
        cap2.append(buf48)
        // 160-sample slack absorbs converter latency/edge frames
        precondition(abs(cap2.samples.count - 16000) <= 160, "48k→16k resample count off: \(cap2.samples.count)")

        print("AudioCapture16kTests passed")
    }
}

import AVFoundation

@main
struct AudioCapture16kTestRunner {
    static func main() {
        let cap = AudioCapture16k()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000)!
        buf.frameLength = 16000
        var lastLevel: Float = -1
        cap.onAudioLevel = { lastLevel = $0 }
        cap.appendForTest(buf)
        precondition(cap.samples.count == 16000, "should accumulate 16000 samples (\(cap.samples.count))")
        precondition(lastLevel >= 0 && lastLevel <= 1, "level normalized 0..1 (\(lastLevel))")
        print("AudioCapture16kTests passed")
    }
}

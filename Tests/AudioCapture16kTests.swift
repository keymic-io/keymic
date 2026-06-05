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
        precondition(cap.snapshot().count == 16000, "should accumulate 16000 samples (\(cap.snapshot().count))")
        precondition(level >= 0 && level <= 1, "level normalized 0..1 (\(level))")

        // resampling: 48k mono → expect ~16000 (×1/3) appended via the real append() converter path
        let cap2 = AudioCapture16k()
        let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buf48 = AVAudioPCMBuffer(pcmFormat: fmt48, frameCapacity: 48000)!
        buf48.frameLength = 48000
        cap2.append(buf48)
        // 160-sample slack absorbs converter latency/edge frames
        precondition(abs(cap2.snapshot().count - 16000) <= 160, "48k→16k resample count off: \(cap2.snapshot().count)")

        // concurrency: 写线程持续 accumulate,主线程并发 snapshot;
        // 断言每个快照都落在 append 边界(无撕裂)、计数单调不退、不越界、不崩溃。
        let cap3 = AudioCapture16k()
        let chunk = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!
        chunk.frameLength = 1600
        let iterations = 500
        let writer = Thread {
            for _ in 0..<iterations { cap3.accumulate(chunk) }
        }
        writer.start()
        // Heuristic smoke test: the standalone swiftc runner has no ThreadSanitizer,
        // so this exercises the lock under contention rather than proving race-freedom.
        var maxSeen = 0
        var done = false
        while !done {
            let c = cap3.snapshot().count
            precondition(c % 1600 == 0, "snapshot not on append boundary: \(c)")
            precondition(c <= iterations * 1600, "snapshot exceeds total: \(c)")
            precondition(c >= maxSeen, "snapshot count went backwards: \(c) < \(maxSeen)")
            maxSeen = c
            done = writer.isFinished && c == iterations * 1600
        }
        precondition(cap3.snapshot().count == iterations * 1600,
                     "final snapshot count wrong: \(cap3.snapshot().count)")
        print("AudioCapture16k concurrency test passed")

        print("AudioCapture16kTests passed")
    }
}

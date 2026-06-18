import Foundation

@main
struct SystemAudioSmoke {
    static func main() async {
        let capture = SystemAudioCapture()
        let box = Box()
        capture.onSamples = { samples in box.append(samples) }
        capture.onError = { msg in
            FileHandle.standardError.write(Data("stream error: \(msg)\n".utf8))
        }

        do {
            try await capture.start()
        } catch {
            FileHandle.standardError.write(Data("start failed: \(error)\n".utf8))
            exit(2)
        }

        print("capturing system audio for 5s — PLAY SOME AUDIO NOW")
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        await capture.stop()

        let (count, rms) = box.summary()
        print("captured \(count) samples @16k (\(String(format: "%.2f", Double(count)/16000.0))s), rms=\(String(format: "%.4f", rms))")
        guard count > 16000 else {   // expect >1s of audio in 5s of wall time
            FileHandle.standardError.write(Data("too few samples — capture not flowing\n".utf8))
            exit(3)
        }
        print("SystemAudioSmoke passed")
    }
}

/// Thread-safe accumulator (onSamples fires on the capture queue).
final class Box {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ s: [Float]) { lock.lock(); samples.append(contentsOf: s); lock.unlock() }
    func summary() -> (Int, Float) {
        lock.lock(); defer { lock.unlock() }
        let rms = samples.isEmpty ? 0 : sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        return (samples.count, rms)
    }
}

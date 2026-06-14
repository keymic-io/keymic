import AVFoundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "AudioCapture16k")

/// 把麦克风音频转 16k 单声道 Float32 并整句累积(batch ASR 用)。
final class AudioCapture16k {
    var onAudioLevel: ((Float) -> Void)?
    private var samples: [Float] = []

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SenseVoiceConfig.sampleRate,
        channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    /// Guards `samples` and `converter` against the audio-tap thread (append)
    /// racing the partial timer / main thread (snapshot, reset). RMS math stays
    /// outside the lock to keep the real-time audio thread unblocked.
    private let lock = NSLock()

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        converter = nil
        lock.unlock()
    }

    /// 由 tap 回调调用:转 16k、累积、报 RMS(回调投递到主线程)。
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let conv: AVAudioConverter
        if let c = converter { conv = c }
        else {
            guard let c = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                lock.unlock()
                logger.error("AVAudioConverter init failed"); return
            }
            converter = c; conv = c
        }
        lock.unlock()
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if let err { logger.error("convert error: \(err.localizedDescription, privacy: .public)"); return }
        let level = accumulate(out)
        DispatchQueue.main.async { [weak self] in self?.onAudioLevel?(level) }
    }

    /// 累积样本并返回归一化 RMS level(0..1)。
    @discardableResult
    func accumulate(_ out: AVAudioPCMBuffer) -> Float {
        guard let ch = out.floatChannelData?[0] else { return 0 }
        let n = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        lock.unlock()
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrtf(sum / Float(max(n, 1)))
        let dB = 20 * log10(max(rms, 1e-6))
        return max(Float(0), min(Float(1), (dB + 50) / 40))
    }

    /// Thread-safe copy of accumulated samples. The partial timer calls this
    /// while the audio tap thread keeps appending. Returning under the lock
    /// makes the COW retain atomic w.r.t. `accumulate`'s in-place append.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

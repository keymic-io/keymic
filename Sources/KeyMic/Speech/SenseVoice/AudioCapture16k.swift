import AVFoundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "AudioCapture16k")

/// 把麦克风音频转 16k 单声道 Float32 并整句累积(batch ASR 用)。
final class AudioCapture16k {
    var onAudioLevel: ((Float) -> Void)?
    private(set) var samples: [Float] = []

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SenseVoiceConfig.sampleRate,
        channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    func reset() { samples.removeAll(keepingCapacity: true); converter = nil }

    /// 由 tap 回调调用:转 16k、累积、报 RMS(回调投递到主线程)。
    func append(_ buffer: AVAudioPCMBuffer) {
        let conv: AVAudioConverter
        if let c = converter { conv = c }
        else {
            guard let c = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                logger.error("AVAudioConverter init failed"); return
            }
            converter = c; conv = c
        }
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
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrtf(sum / Float(max(n, 1)))
        let dB = 20 * log10(max(rms, 1e-6))
        return max(Float(0), min(Float(1), (dB + 50) / 40))
    }
}

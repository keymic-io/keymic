import AVFoundation
import Foundation

// AR funasr_nano 延迟基准。遍历 wav 列表,init 一次性计时,decode 每条计时,
// 打印 TRANSCRIPT / decode_ms / 音频时长 / RTF(= decode_s / audio_s)。
@main
struct FunASRARSpike {
    static func appSupport(_ rel: String) -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/KeyMic/\(rel)")
    }

    // 用 AVAudioFile 读 wav 时长(秒)。失败返回 0。
    static func audioSeconds(_ path: String) -> Double {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let frames = Double(file.length)
        let sr = file.fileFormat.sampleRate
        return sr > 0 ? frames / sr : 0
    }

    static func main() {
        let onnxDir  = appSupport("onnx-runtime")
        let modelDir = appSupport("models/funasr-nano-ar")

        // [label, wav 绝对/相对路径]
        let wavs: [(String, String)] = [
            ("zh.wav",              "Tests/Spikes/fixtures/zh.wav"),
            ("ja_en_codeswitch.wav", modelDir + "/test_wavs/ja_en_codeswitch.wav"),
            ("rag_math.wav",        modelDir + "/test_wavs/rag_math.wav"),
            ("far_2.wav",           modelDir + "/test_wavs/far_2.wav"),
        ]

        var firstInitMs: Double = 0
        var anyFail = false

        for (idx, (label, wav)) in wavs.enumerated() {
            var buf = [CChar](repeating: 0, count: 8192)
            var initMs: Double = 0
            var decodeMs: Double = 0
            let rc = spike_ar_decode(onnxDir, modelDir, wav, &buf, Int32(buf.count), &initMs, &decodeMs)
            let text = String(cString: buf)

            if idx == 0 { firstInitMs = initMs }

            guard rc == 0 else {
                print("SPIKE_FAIL [\(label)] rc=\(rc): \(text)")
                anyFail = true
                // 若首条 init 就失败(rc<=4),后续无意义,直接退出。
                if rc <= 4 { exit(1) }
                continue
            }

            let audioS = audioSeconds(wav)
            let decodeS = decodeMs / 1000.0
            let rtf = audioS > 0 ? decodeS / audioS : -1

            print("=== \(label) ===")
            print("  TRANSCRIPT: [\(text)]")
            print(String(format: "  audio_s=%.3f  decode_ms=%.1f  RTF=%.3f", audioS, decodeMs, rtf))
            if initMs > 0 { print(String(format: "  init_ms=%.1f (one-time)", initMs)) }
        }

        print("---")
        print(String(format: "ONE_TIME_INIT_MS: %.1f", firstInitMs))
        print(anyFail ? "SPIKE_DONE_WITH_FAILURES" : "SPIKE_PASS")
        if anyFail { exit(2) }
    }
}

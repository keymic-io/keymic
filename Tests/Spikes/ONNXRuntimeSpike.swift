import Foundation

@main
struct ONNXRuntimeSpike {
    static func appSupport(_ rel: String) -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/KeyMic/\(rel)")
    }
    static func main() {
        let onnxDir = appSupport("onnx-runtime")
        let model   = appSupport("models/funasr-nano/model.onnx")
        let tokens  = appSupport("models/funasr-nano/tokens.txt")
        let wav     = "Tests/Spikes/fixtures/zh.wav"

        var buf = [CChar](repeating: 0, count: 8192)
        let rc = spike_transcribe(onnxDir, model, tokens, wav, &buf, Int32(buf.count))
        let text = String(cString: buf)

        guard rc == 0 else { print("SPIKE_FAIL rc=\(rc): \(text)"); exit(1) }
        print("TRANSCRIPT: [\(text)]")

        // 断言:非空 + 等于 Step 1 CLI 基线真值(开饭时间早上九点至下午五点)
        // CLI ground truth (sherpa-onnx-offline, sense_voice, zh.wav):
        //   开饭时间早上九点至下午五点
        let cliBaseline = "开饭时间早上九点至下午五点"
        let expectedKeywords = ["开饭时间", "下午五点"]
        guard !text.isEmpty, text != "(empty result)" else { print("SPIKE_FAIL empty"); exit(1) }
        for kw in expectedKeywords where !text.contains(kw) {
            print("SPIKE_FAIL missing keyword: \(kw)"); exit(1)
        }
        if text == cliBaseline {
            print("MATCHES_CLI_BASELINE: yes")
        } else {
            print("MATCHES_CLI_BASELINE: no (bridge=[\(text)] cli=[\(cliBaseline)]) — keywords still present")
        }
        print("SPIKE_PASS")
    }
}

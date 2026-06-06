import Foundation

@main
struct CTCDecoderTestRunner {
    static func main() {
        // 1. 合成单元测试:小词表,decode(ids:) → "hello world"
        let tmp = NSTemporaryDirectory() + "vocab_ctc.json"
        try! #"{"<blank>":0,"<|zh|>":1,"<|EMO_UNKNOWN|>":2,"<|Speech|>":3,"<|woitn|>":4,"▁hello":5,"▁world":6}"#
            .write(toFile: tmp, atomically: true, encoding: .utf8)
        let dec = CTCDecoder(vocab: SenseVoiceVocab(jsonPath: tmp), blankId: 0)
        let ids = [1, 2, 3, 4, 5, 5, 0, 6]  // tags + hello + repeat + blank + world
        let text = dec.decode(ids: ids)
        precondition(text == "hello world", "synthetic decode got: '\(text)'")

        // 2. decode(logits:) argmax 路径:每帧 argmax 等价上面 ids 的前缀
        let logits: [[Float]] = [[0, 9, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 9, 0]]  // frame0→id1(<|zh|>), frame1→id5(▁hello)
        precondition(
            dec.decode(logits: logits) == "hello", "logits decode got: '\(dec.decode(logits: logits))'")

        // 3. golden:真实模型 argmax → collapse 等于 ctc_collapsed_no_blank,decode 为空(控制标签全 strip)
        let real = CTCDecoder(
            vocab: SenseVoiceVocab(
                spmModelPath: "Resources/sensevoice/chn_jpn_yue_eng_ko_spectok.bpe.model"),
            blankId: 0)
        let s = loadSampleIds("Tests/Support/sensevoice/sample_ids.json")
        precondition(
            real.collapse(s.greedyRaw) == s.collapsedNoBlank,
            "collapse mismatch: \(real.collapse(s.greedyRaw)) vs \(s.collapsedNoBlank)")
        let expected =
            (try? String(
                contentsOfFile: "Tests/Support/sensevoice/sample_expected.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        precondition(
            real.decode(ids: s.greedyRaw) == expected,
            "golden decode got: '\(real.decode(ids: s.greedyRaw))' expected: '\(expected)'")

        print("CTCDecoderTests passed")
    }

    struct SampleIds: Decodable {
        let greedyRaw: [Int]
        let collapsedNoBlank: [Int]
        enum CodingKeys: String, CodingKey {
            case greedyRaw = "greedy_raw"
            case collapsedNoBlank = "ctc_collapsed_no_blank"
        }
    }
    static func loadSampleIds(_ path: String) -> SampleIds {
        let data = FileManager.default.contents(atPath: path)!
        return try! JSONDecoder().decode(SampleIds.self, from: data)
    }
}

import Foundation

@main
struct SenseVoiceVocabTestRunner {
    static func main() {
        // 针对真实提交的 SentencePiece .model(protobuf)做运行时解析校验。
        let v = SenseVoiceVocab(
            spmModelPath: "Resources/sensevoice/chn_jpn_yue_eng_ko_spectok.bpe.model")

        // 总 piece 数(= ctc_logits 末维,实测 25055)。
        precondition(v.count == 25055, "count got: \(v.count)")

        // 已知 id→token 映射(取自旧 vocab.json,CTC golden 测试依赖):证明 piece 顺序与旧词表一致。
        let known: [(Int, String)] = [
            (0, "<unk>"),
            (24992, "<|nospeech|>"),
            (25009, "<|EMO_UNKNOWN|>"),
            (25019, "<|Event_UNK|>"),
            (25017, "<|woitn|>"),
        ]
        for (id, tok) in known {
            precondition(v.token(for: id) == tok, "id \(id) → '\(v.token(for: id))' expected '\(tok)'")
        }

        // 越界 id → 空串。
        precondition(v.token(for: 999_999) == "", "out-of-range id → empty")

        print("SenseVoiceVocabTests passed")
    }
}

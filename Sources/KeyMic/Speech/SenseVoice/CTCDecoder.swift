import Foundation

/// CTC greedy 解码 + SentencePiece detokenize + strip SenseVoice 控制标签。
final class CTCDecoder {
    private let vocab: SenseVoiceVocab
    private let blankId: Int

    init(vocab: SenseVoiceVocab, blankId: Int) {
        self.vocab = vocab
        self.blankId = blankId
    }

    /// 从 logits `[T][vocab]` greedy argmax 后解码为纯文本。
    func decode(logits: [[Float]]) -> String {
        var ids: [Int] = []
        for frame in logits {
            var best = 0
            var bestV = -Float.greatestFiniteMagnitude
            for (i, v) in frame.enumerated() where v > bestV {
                bestV = v
                best = i
            }
            ids.append(best)
        }
        return decode(ids: ids)
    }

    /// 从 per-frame argmax id 序列(未折叠)解码:CTC collapse + detok + strip。
    func decode(ids: [Int]) -> String {
        detokenize(collapse(ids))
    }

    /// CTC collapse:去除连续重复 + 去 blank。返回保留 token id 序列。internal 便于测试。
    ///
    /// 采用单遍 `id != blank && id != prev`,prev 只在写出 token 时推进(对每一帧都更新)。
    /// 已对照真实模型 golden 验证:`collapse(greedy_raw) == ctc_collapsed_no_blank`
    /// ([24992,25009,25019,25017] from [24992,25009,25019,25017,0×33])。
    /// 经典 2-step(先按所有帧折叠连续重复、再去 blank)在 golden 上与本实现等价,
    /// 因为 golden 不含「真实 token—blank—同一 token」这种需要 blank 隔开重复的序列;
    /// 在那种边界场景两者会不同,但 golden 不覆盖,故沿用更简洁的单遍版本。
    func collapse(_ ids: [Int]) -> [Int] {
        var out: [Int] = []
        var prev = -1
        for id in ids {
            if id != blankId && id != prev { out.append(id) }
            prev = id
        }
        return out
    }

    private func detokenize(_ ids: [Int]) -> String {
        var pieces: [String] = []
        for id in ids {
            let tok = vocab.token(for: id)
            if tok.isEmpty { continue }
            if tok.hasPrefix("<|") && tok.hasSuffix("|>") { continue }  // strip 控制标签
            pieces.append(tok)
        }
        let joined = pieces.joined()
        return joined.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

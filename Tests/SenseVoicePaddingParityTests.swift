import CoreML
import Foundation

/// Model-gated parity test for the int8 export graph's zero-pad attention mask.
///
/// The int8 CoreML model is `EnumeratedShapes`: `speech` only accepts T ∈
/// `modelFrameBuckets` (128/256/512/1024/1800), so any non-bucket-boundary length is
/// zero-padded up to the nearest bucket and the true length is carried in `speech_lengths`.
/// The export graph is expected to use `speech_lengths` to build an attention mask that
/// isolates the pad frames — if that mask were ineffective, pad frames would leak into the
/// real frames through encoder self-attention and corrupt the transcript, and the corruption
/// would grow with the pad ratio (95 pad frames at bucket 128 → 1767 at bucket 1800).
///
/// This test proves the mask by INVARIANCE: it feeds the SAME 33 real fbank frames
/// (`hello_fbank.json`, `speech_lengths` held at 33) into EVERY bucket and asserts the
/// collapsed-CTC id sequence is identical across all of them — and equal to the committed
/// golden (`sample_ids.json`). Because the only thing that changes between runs is the amount
/// of trailing zero-pad, an identical decode means the pad frames contribute nothing to the
/// real-frame encoder output at any bucket size.
///
/// Requires the 226 MB int8 model on disk (`SenseVoiceModelStore.shared`). CI and dev machines
/// without the model SKIP gracefully (exit 0) — the model can't be loaded on macOS <15 and is
/// not committed to the repo, so this can only run where a real install exists.
@main
struct SenseVoicePaddingParityTestRunner {
    static func main() {
        let store = SenseVoiceModelStore.shared
        guard case .ready = store.state, let model = store.loadModel() else {
            print("SenseVoicePaddingParityTests skipped (int8 model not installed at \(store.modelURL.path))")
            return
        }

        // Real content + committed golden. `hello_fbank.json` is 33 LFR-fbank frames; the golden
        // collapsed-CTC ids come from the same fixture used by CTCDecoderTests.
        let feats = GoldenLoader.loadMatrix("Tests/Support/sensevoice/hello_fbank.json")
        let goldenCollapsed = loadGolden("Tests/Support/sensevoice/sample_ids.json")
        let trueT = feats.count
        precondition(trueT > 0, "empty fbank fixture")
        // The fixture must be shorter than every bucket so each run genuinely exercises padding.
        precondition(trueT < SenseVoiceConfig.modelFrameBuckets.first!,
                     "fixture (\(trueT) frames) must be < smallest bucket to exercise padding")

        let vocab = SenseVoiceVocab(
            spmModelPath: "Resources/sensevoice/chn_jpn_yue_eng_ko_spectok.bpe.model")
        let decoder = CTCDecoder(vocab: vocab, blankId: SenseVoiceConfig.blankId)

        var perBucket: [(bucket: Int, ids: [Int])] = []
        for bucket in SenseVoiceConfig.modelFrameBuckets {
            let logits = try! infer(model: model, features: feats, trueT: trueT, bucket: bucket)
            let ids = decoder.collapse(argmax(logits))
            perBucket.append((bucket, ids))
        }

        // 1. Invariance: every bucket collapses to the same id sequence as the smallest bucket.
        let baseline = perBucket[0]
        for entry in perBucket where entry.ids != baseline.ids {
            fatalError(
                "pad mask leak: bucket \(entry.bucket) collapsed \(entry.ids) != bucket "
                + "\(baseline.bucket) \(baseline.ids) — pad frames corrupted the real-frame output")
        }
        // 2. Correctness anchor: the invariant result matches the committed golden.
        precondition(
            baseline.ids == goldenCollapsed,
            "collapsed-CTC \(baseline.ids) != golden \(goldenCollapsed)")

        let buckets = perBucket.map { String($0.bucket) }.joined(separator: "/")
        print("SenseVoicePaddingParityTests passed (bit-stable collapsed-CTC across buckets \(buckets))")
    }

    /// Build the model's 4 inputs with the 33 real frames zero-padded to `bucket` while holding
    /// `speech_lengths` at the true length, run inference, and trim to the valid frames.
    ///
    /// This mirrors `SenseVoiceModel.makeFeatureProvider`'s layout but forces a chosen bucket:
    /// the production builder always picks the SMALLEST bucket ≥ T, so it can't hold one real
    /// length constant while varying the pad amount — which is exactly the axis this test needs.
    static func infer(model: MLModel, features: [[Float]], trueT: Int, bucket: Int) throws -> [[Float]] {
        let d = features[0].count
        let speech = try MLMultiArray(
            shape: [1, NSNumber(value: bucket), NSNumber(value: d)], dataType: .float32)
        memset(speech.dataPointer, 0, bucket * d * MemoryLayout<Float32>.size)
        let ptr = speech.dataPointer.bindMemory(to: Float32.self, capacity: bucket * d)
        var idx = 0
        for row in features { for v in row { ptr[idx] = v; idx += 1 } }

        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: trueT)
        let language = try MLMultiArray(shape: [1], dataType: .int32); language[0] = 0  // auto
        // Pin woitn (not the app's mutable `defaultTextNorm`): the committed golden in
        // sample_ids.json was captured in woitn mode, and the pad-mask invariance this test
        // asserts is independent of the textnorm embedding anyway.
        let textnorm = try MLMultiArray(shape: [1], dataType: .int32)
        textnorm[0] = NSNumber(value: SenseVoiceConfig.textNormWithoutITN)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            SenseVoiceConfig.inputFeatureName: MLFeatureValue(multiArray: speech),
            SenseVoiceConfig.inputLengthName: MLFeatureValue(multiArray: lengths),
            SenseVoiceConfig.inputLanguageName: MLFeatureValue(multiArray: language),
            SenseVoiceConfig.inputTextNormName: MLFeatureValue(multiArray: textnorm),
        ])
        let out = try model.prediction(from: provider)
        let logits = out.featureValue(for: SenseVoiceConfig.outputLogitsName)!.multiArrayValue!
        let shape = logits.shape.map { $0.intValue }  // [1, T', V]
        let framesTotal = shape[shape.count - 2]
        let vocabN = shape[shape.count - 1]
        // int8 export omits encoder_out_lens → valid frames = trueT + controlFrames.
        let valid = min(framesTotal, trueT + SenseVoiceConfig.controlFrames)
        var mat = [[Float]](repeating: [Float](repeating: 0, count: vocabN), count: valid)
        for f in 0..<valid {
            let base = f * vocabN
            for v in 0..<vocabN { mat[f][v] = logits[base + v].floatValue }
        }
        return mat
    }

    static func argmax(_ logits: [[Float]]) -> [Int] {
        logits.map { frame in
            var best = 0
            var bestV = -Float.greatestFiniteMagnitude
            for (i, v) in frame.enumerated() where v > bestV { bestV = v; best = i }
            return best
        }
    }

    struct SampleIds: Decodable {
        let collapsedNoBlank: [Int]
        enum CodingKeys: String, CodingKey { case collapsedNoBlank = "ctc_collapsed_no_blank" }
    }
    static func loadGolden(_ path: String) -> [Int] {
        let data = FileManager.default.contents(atPath: path)!
        return try! JSONDecoder().decode(SampleIds.self, from: data).collapsedNoBlank
    }
}

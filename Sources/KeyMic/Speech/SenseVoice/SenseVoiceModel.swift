import CoreML
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SenseVoiceModel")

/// Wraps the SenseVoiceSmall CoreML model: builds its 4 inputs from LFR-fbank features,
/// runs inference, returns raw CTC logits trimmed to the valid encoder length.
///
/// Intentionally NOT annotated `@available(macOS 15)`: the CoreML APIs used here all compile
/// on the macOS 14 SDK. The model only fails to *load* on macOS <15 — that is handled upstream
/// by `SenseVoiceModelStore.loadModel()` (returns nil) and the engine factory's fallback to
/// Apple's recognizer. Keeping this type un-annotated lets the input-builder unit test run on
/// any host without the 432 MB model.
final class SenseVoiceModel {
    private let model: MLModel

    init(model: MLModel) { self.model = model }

    /// Build the model's 4-input dictionary. Model-free + `static` so it is unit-testable
    /// without loading the (432 MB) `MLModel`.
    ///
    /// - `speech`         Float32 `[1, T, D]` — LFR-fbank features (row-major fill).
    /// - `speech_lengths` Int32   `[1]` = T.
    /// - `language`       Int32   `[1]` — embedding index (auto=0, zh=3, en=4, …).
    /// - `textnorm`       Int32   `[1]` — embedding index (withitn=14, woitn=15).
    static func makeFeatureProvider(
        features: [[Float]], languageId: Int, textnormId: Int
    ) throws -> MLDictionaryFeatureProvider {
        // The exported `speech` input only accepts T in 1...modelMaxFrames (~3 min). A longer
        // hold would make `model.prediction` throw on a shape/range mismatch and lose the whole
        // transcript; truncate to the cap (drop the tail) so we still return a partial result.
        let features: [[Float]] = {
            guard features.count > SenseVoiceConfig.modelMaxFrames else { return features }
            logger.warning("feature frames \(features.count, privacy: .public) capped at \(SenseVoiceConfig.modelMaxFrames, privacy: .public); tail dropped")
            return Array(features.prefix(SenseVoiceConfig.modelMaxFrames))
        }()
        let t = features.count
        let d = features.first?.count ?? SenseVoiceConfig.modelFeatureDim

        let speech = try MLMultiArray(
            shape: [1, NSNumber(value: t), NSNumber(value: d)], dataType: .float32)
        // Fast contiguous fill via typed pointer (row-major: idx = ti*d + di).
        let ptr = speech.dataPointer.bindMemory(to: Float32.self, capacity: t * d)
        var idx = 0
        for row in features {
            for v in row {
                ptr[idx] = v
                idx += 1
            }
        }

        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: t)
        let language = try MLMultiArray(shape: [1], dataType: .int32)
        language[0] = NSNumber(value: languageId)
        let textnorm = try MLMultiArray(shape: [1], dataType: .int32)
        textnorm[0] = NSNumber(value: textnormId)

        return try MLDictionaryFeatureProvider(dictionary: [
            SenseVoiceConfig.inputFeatureName: MLFeatureValue(multiArray: speech),
            SenseVoiceConfig.inputLengthName: MLFeatureValue(multiArray: lengths),
            SenseVoiceConfig.inputLanguageName: MLFeatureValue(multiArray: language),
            SenseVoiceConfig.inputTextNormName: MLFeatureValue(multiArray: textnorm),
        ])
    }

    /// Run inference → raw CTC logits `[T'][V]` trimmed to `encoder_out_lens`.
    /// `T' = T + 4` (the model prepends 4 control-embedding frames); the CTCDecoder strips
    /// their argmax tags. Logit width V == `SenseVoiceConfig.vocabSize` (25055).
    func infer(features: [[Float]], languageId: Int, textnormId: Int) throws -> [[Float]] {
        let provider = try Self.makeFeatureProvider(
            features: features, languageId: languageId, textnormId: textnormId)
        let out = try model.prediction(from: provider)
        guard let logits = out.featureValue(for: SenseVoiceConfig.outputLogitsName)?.multiArrayValue
        else {
            throw VoiceError.audioEngineFailed(
                "SenseVoice model produced no \(SenseVoiceConfig.outputLogitsName)")
        }

        let shape = logits.shape.map { $0.intValue }  // [1, T', V]
        guard shape.count >= 2 else {
            throw VoiceError.audioEngineFailed(
                "SenseVoice \(SenseVoiceConfig.outputLogitsName) has unexpected rank \(shape.count)")
        }
        let framesTotal = shape[shape.count - 2]
        let vocab = shape[shape.count - 1]

        // Valid frame count from encoder_out_lens (clamp to framesTotal; fall back to all frames).
        var validFrames = framesTotal
        if let lens = out.featureValue(for: SenseVoiceConfig.outputLengthName)?.multiArrayValue,
           lens.count > 0 {
            validFrames = min(framesTotal, lens[0].intValue)
        }
        guard validFrames > 0, vocab > 0 else { return [] }

        // Read logits row-major [t*vocab + v]. The model stores Float16; the NSNumber subscript
        // bridges it to Float regardless of backing dtype. Only validFrames × vocab reads.
        var result = [[Float]](
            repeating: [Float](repeating: 0, count: vocab), count: validFrames)
        for f in 0..<validFrames {
            let base = f * vocab
            for v in 0..<vocab {
                result[f][v] = logits[base + v].floatValue
            }
        }
        return result
    }
}

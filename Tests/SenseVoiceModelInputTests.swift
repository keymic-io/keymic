import CoreML
import Foundation

/// Model-free unit test for `SenseVoiceModel.makeFeatureProvider`. We can't load the 226 MB
/// CoreML model in CI, so the input builder is a `static func` callable without an `MLModel`.
/// This verifies the 4 inputs are constructed with the right names / shapes / dtypes / values.
@main
struct SenseVoiceModelInputTestRunner {
    static func main() {
        let features: [[Float]] = [
            [Float](repeating: 1.5, count: 560),
            [Float](repeating: -2.0, count: 560),
        ]
        let provider = try! SenseVoiceModel.makeFeatureProvider(
            features: features, languageId: 3, textnormId: 15)

        let speech = provider.featureValue(for: SenseVoiceConfig.inputFeatureName)!.multiArrayValue!
        // T=2 pads to the smallest EnumeratedShapes bucket ≥ 2 → 128 (see bucket padding below).
        precondition(speech.shape.map { $0.intValue } == [1, 128, 560], "speech shape \(speech.shape)")
        precondition(speech.dataType == .float32, "speech dtype \(speech.dataType.rawValue)")
        // row-major [1, T, D]: row 0 starts at index 0, row 1 starts at index D=560.
        precondition(speech[0].floatValue == 1.5 && speech[560].floatValue == -2.0, "speech values")

        let len = provider.featureValue(for: SenseVoiceConfig.inputLengthName)!.multiArrayValue!
        precondition(len.shape.map { $0.intValue } == [1], "length shape \(len.shape)")
        precondition(len.dataType == .int32, "length dtype \(len.dataType.rawValue)")
        precondition(len[0].intValue == 2, "length")

        let lang = provider.featureValue(for: SenseVoiceConfig.inputLanguageName)!.multiArrayValue!
        precondition(lang.dataType == .int32, "language dtype \(lang.dataType.rawValue)")
        precondition(lang[0].intValue == 3, "language")

        let tnorm = provider.featureValue(for: SenseVoiceConfig.inputTextNormName)!.multiArrayValue!
        precondition(tnorm.dataType == .int32, "textnorm dtype \(tnorm.dataType.rawValue)")
        precondition(tnorm[0].intValue == 15, "textnorm")

        // --- EnumeratedShapes bucket padding (int8 model) ---
        do {
            // T=33 → padded to bucket 128, true length preserved, pad region zeroed
            let feats = [[Float]](repeating: [Float](repeating: 1.5, count: 560), count: 33)
            let p = try! SenseVoiceModel.makeFeatureProvider(features: feats, languageId: 0, textnormId: 15)
            let speech = p.featureValue(for: SenseVoiceConfig.inputFeatureName)!.multiArrayValue!
            precondition(speech.shape[1].intValue == 128, "T=33 pads to 128 (got \(speech.shape[1]))")
            let lens = p.featureValue(for: SenseVoiceConfig.inputLengthName)!.multiArrayValue!
            precondition(lens[0].intValue == 33, "speech_lengths keeps true T (got \(lens[0]))")
            let ptr = speech.dataPointer.bindMemory(to: Float32.self, capacity: 128 * 560)
            precondition(ptr[32 * 560] == 1.5, "last real frame intact")
            precondition(ptr[33 * 560] == 0, "pad region zeroed")
            precondition(ptr[127 * 560 + 559] == 0, "pad tail zeroed")
        }
        do {
            // exact bucket size stays as-is
            let feats = [[Float]](repeating: [Float](repeating: 1, count: 560), count: 256)
            let p = try! SenseVoiceModel.makeFeatureProvider(features: feats, languageId: 0, textnormId: 15)
            let speech = p.featureValue(for: SenseVoiceConfig.inputFeatureName)!.multiArrayValue!
            precondition(speech.shape[1].intValue == 256, "T=256 stays 256")
        }
        do {
            // over the max bucket → capped at 1800
            let feats = [[Float]](repeating: [Float](repeating: 1, count: 560), count: 1801)
            let p = try! SenseVoiceModel.makeFeatureProvider(features: feats, languageId: 0, textnormId: 15)
            let speech = p.featureValue(for: SenseVoiceConfig.inputFeatureName)!.multiArrayValue!
            precondition(speech.shape[1].intValue == 1800, "T=1801 capped at 1800")
            let lens = p.featureValue(for: SenseVoiceConfig.inputLengthName)!.multiArrayValue!
            precondition(lens[0].intValue == 1800, "capped true T = 1800")
        }

        print("SenseVoiceModelInputTests passed")
    }
}

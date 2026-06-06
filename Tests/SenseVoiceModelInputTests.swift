import CoreML
import Foundation

/// Model-free unit test for `SenseVoiceModel.makeFeatureProvider`. We can't load the 432 MB
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
        precondition(speech.shape.map { $0.intValue } == [1, 2, 560], "speech shape \(speech.shape)")
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

        print("SenseVoiceModelInputTests passed")
    }
}

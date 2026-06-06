import Foundation

@main
struct FbankExtractorTestRunner {
    static func main() {
        let wav = GoldenLoader.loadWav16k("Tests/Support/sensevoice/hello_16k.wav")
        let golden = GoldenLoader.loadMatrix("Tests/Support/sensevoice/hello_fbank.json")
        let ex = FbankExtractor(mvnPath: "Resources/sensevoice/am.mvn")
        let feat = ex.extract(samples: wav)
        precondition(feat.count == golden.count, "frame count \(feat.count) vs golden \(golden.count)")
        var maxErr: Float = 0
        for t in 0..<feat.count {
            precondition(
                feat[t].count == golden[t].count,
                "dim mismatch at frame \(t): \(feat[t].count) vs \(golden[t].count)")
            for d in 0..<feat[t].count { maxErr = max(maxErr, abs(feat[t][d] - golden[t][d])) }
        }
        print("maxErr=\(maxErr)")
        precondition(maxErr < 1e-2, "fbank deviates from golden, maxErr=\(maxErr)")
        print("FbankExtractorTests passed")
    }
}

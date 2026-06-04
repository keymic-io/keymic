import Foundation

@main
struct SenseVoiceVocabTestRunner {
    static func main() {
        let tmp = NSTemporaryDirectory() + "vocab_test.json"
        try! #"{"<blank>":0,"▁hello":5,"world":6,"<|zh|>":100}"#.write(toFile: tmp, atomically: true, encoding: .utf8)
        let v = SenseVoiceVocab(jsonPath: tmp)
        precondition(v.token(for: 5) == "▁hello", "id→token")
        precondition(v.token(for: 999) == "", "unknown id → empty")
        precondition(v.count == 4, "count")
        print("SenseVoiceVocabTests passed")
    }
}

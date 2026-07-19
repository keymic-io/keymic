import Foundation

/// Manual smoke: exercise CTPunctuationBridge end-to-end against the on-disk CT-transformer model.
/// Verifies Chinese (and mixed zh-en) text comes back with punctuation inserted.
@main
struct CTPunctSmoke {
    static func main() {
        guard ONNXRuntimeLoader.shared.loadIfReady() else {
            FileHandle.standardError.write(Data("runtime not loaded — populate onnx-runtime/ first\n".utf8))
            exit(2)
        }
        guard let bridge = CTPunctuationBridge.create() else {
            FileHandle.standardError.write(Data("CTPunctuationBridge.create() returned nil — model missing or create failed\n".utf8))
            exit(3)
        }
        let inputs = [
            "我们都是木头人不会说话不会动",
            "今天天气很好我们一起去公园好不好",
            "这是一个测试你好吗how are you我很好thank you",
        ]
        var failed = false
        for s in inputs {
            let out = bridge.addPunct(s)
            print("IN : \(s)")
            print("OUT: \(out)")
            print("changed: \(out != s)")
            print("---")
            if out == s { failed = true }
        }
        if failed {
            FileHandle.standardError.write(Data("FAIL: some input had no punctuation added\n".utf8))
            exit(1)
        }
        print("CTPunctSmoke passed")
    }
}

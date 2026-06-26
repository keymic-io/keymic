import Foundation

/// Manual smoke: exercise PunctuationBridge end-to-end against the on-disk online-punct-en model.
/// Mirrors the exact runtime path the meeting pipeline uses (loadIfReady → create → addPunct).
@main
struct PunctSmoke {
    static func main() {
        guard ONNXRuntimeLoader.shared.loadIfReady() else {
            FileHandle.standardError.write(Data("runtime not loaded — populate onnx-runtime/ first\n".utf8))
            exit(2)
        }
        guard let bridge = PunctuationBridge.create() else {
            FileHandle.standardError.write(Data("PunctuationBridge.create() returned nil — model missing or create failed\n".utf8))
            exit(3)
        }
        // ALL-CAPS inputs mirror the streaming zipformer's real output. After the lowercase-first
        // fix in addPunct, each must come back re-cased + punctuated (i.e. no longer all-caps).
        let allCaps = [
            "HELLO WORLD HOW ARE YOU",
            "THIS IS A TEST OF THE PUNCTUATION MODEL DOES IT ACTUALLY WORK",
            "I WENT TO NEW YORK WITH JOHN AND MARY ON MONDAY",
        ]
        var failed = false
        for s in allCaps {
            let out = bridge.addPunct(s)
            let stillAllCaps = (out == out.uppercased())
            print("IN : \(s)")
            print("OUT: \(out)")
            print("changed: \(out != s)  stillAllCaps: \(stillAllCaps)")
            print("---")
            if out == s || stillAllCaps { failed = true }
        }
        if failed {
            FileHandle.standardError.write(Data("FAIL: all-caps input was not re-cased/punctuated\n".utf8))
            exit(1)
        }
        print("PunctSmoke passed")
    }
}

import Foundation

@main
struct StreamingASRBridgeNilTests {
    static func main() {
        // No runtime loaded in this standalone runner → create must return nil, not crash.
        let bogus = URL(fileURLWithPath: "/nonexistent/streaming-model-dir")
        let bridge = StreamingASRBridge.create(modelDir: bogus)
        assert(bridge == nil, "create should fail (nil) when runtime not loaded / model absent")
        print("StreamingASRBridgeNilTests passed")
    }
}

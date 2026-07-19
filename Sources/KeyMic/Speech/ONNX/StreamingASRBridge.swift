import CSherpaOnnx
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "StreamingASRBridge")

/// Thin owner of one sherpa-onnx OnlineRecognizer + stream (one audio channel).
/// NOT thread-safe: feed `accept` and read `currentText`/`isEndpoint`/`reset` from a single
/// serial queue per channel (M3's StreamingASREngine owns that queue). `create` requires the
/// ONNX runtime dylibs to be downloaded + dlopen'd (`ONNXRuntimeLoader.shared.loadIfReady()`).
final class StreamingASRBridge {
    private let handle: UnsafeMutableRawPointer

    private init(handle: UnsafeMutableRawPointer) { self.handle = handle }

    /// Returns nil if the runtime isn't ready/loadable or the recognizer fails to build.
    static func create(modelDir: URL) -> StreamingASRBridge? {
        guard ONNXRuntimeLoader.shared.loadIfReady() else {
            logger.error("streaming create: runtime not loaded")
            return nil
        }
        var err = [CChar](repeating: 0, count: 2048)
        guard let h = sherpa_create_online(modelDir.path, &err, Int32(err.count)) else {
            logger.error("sherpa_create_online failed: \(String(cString: err), privacy: .public)")
            return nil
        }
        return StreamingASRBridge(handle: h)
    }

    func accept(_ samples: [Float], sampleRate: Int32 = 16000) {
        guard !samples.isEmpty else { return }
        // baseAddress is non-nil: guarded !samples.isEmpty above
        samples.withUnsafeBufferPointer { buf in
            sherpa_online_accept(handle, buf.baseAddress, Int32(buf.count), sampleRate)
        }
    }

    func currentText() -> String {
        // pre-zeroed: String(cString:) safe even if n == 0
        var out = [CChar](repeating: 0, count: 8192)
        let n = sherpa_online_result(handle, &out, Int32(out.count))
        return n >= 0 ? String(cString: out) : ""
    }

    func isEndpoint() -> Bool {
        let r = sherpa_online_is_endpoint(handle)
        if r < 0 { logger.error("sherpa_online_is_endpoint returned \(r)") }
        return r == 1
    }

    func reset() { sherpa_online_reset(handle) }

    deinit { sherpa_online_destroy(handle) }
}

/// `accept(_:sampleRate:)`, `currentText()`, `isEndpoint()`, `reset()` already match the
/// protocol (the default `sampleRate` argument still satisfies the requirement).
extension StreamingASRBridge: StreamingRecognizing {}

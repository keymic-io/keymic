import CSherpaOnnx
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "CTPunctuationBridge")

/// Thin wrapper over the sherpa-onnx **offline** CT-transformer punctuation C API (reached via the
/// dlopen'd runtime). Adds Chinese/English punctuation (。，？！…) to a complete transcript segment.
/// Unlike the English `PunctuationBridge`, it does NOT change casing (Chinese has none), so the
/// input is passed through verbatim. `addPunct` is a stateless text→text call. NOT thread-safe:
/// the handle must be used from a single serial queue (each meeting source owns its own bridge).
final class CTPunctuationBridge {
    private let handle: UnsafeMutableRawPointer

    private init(handle: UnsafeMutableRawPointer) { self.handle = handle }

    /// Returns nil if the runtime isn't loadable or the model file is missing — callers then fall
    /// back to raw (unpunctuated) text.
    static func create() -> CTPunctuationBridge? {
        guard ONNXRuntimeLoader.shared.loadIfReady() else {
            logger.error("ct-punct create: runtime not loaded"); return nil
        }
        let model = OnnxStores.ctPunct.destDir.appendingPathComponent("model.int8.onnx").path
        guard FileManager.default.fileExists(atPath: model) else {
            logger.error("ct-punct create: model file missing"); return nil
        }
        var err = [CChar](repeating: 0, count: 1024)
        guard let h = sherpa_create_offline_punct(model, &err, Int32(err.count)) else {
            logger.error("sherpa_create_offline_punct failed: \(String(cString: err), privacy: .public)")
            return nil
        }
        return CTPunctuationBridge(handle: h)
    }

    /// Add punctuation for one text chunk. Returns the input unchanged on failure.
    func addPunct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = [CChar](repeating: 0, count: max(8192, text.utf8.count * 2 + 64))
        let n = sherpa_offline_punct_add(handle, text, &out, Int32(out.count))
        return n >= 0 ? String(cString: out) : text
    }

    deinit { sherpa_offline_punct_destroy(handle) }
}

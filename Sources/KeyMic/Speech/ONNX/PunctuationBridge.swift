import CSherpaOnnx
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "PunctuationBridge")

/// Thin wrapper over the sherpa-onnx online-punctuation C API (reached via the dlopen'd runtime).
/// The English `online-punct-en` model adds punctuation AND restores casing — turning the streaming
/// zipformer's all-caps, punctuation-free English into normal-cased, punctuated text.
/// `addPunct` is a stateless text→text call. NOT thread-safe: the handle must be used from a single
/// serial queue (each meeting source owns its own bridge, used on that engine's queue).
final class PunctuationBridge {
    private let handle: UnsafeMutableRawPointer

    private init(handle: UnsafeMutableRawPointer) { self.handle = handle }

    /// Returns nil if the runtime isn't loadable or the punctuation model files are missing —
    /// callers then fall back to raw (unprocessed) text.
    static func create() -> PunctuationBridge? {
        guard ONNXRuntimeLoader.shared.loadIfReady() else {
            logger.error("punct create: runtime not loaded"); return nil
        }
        let dir = OnnxStores.punct.destDir
        let model = dir.appendingPathComponent("model.int8.onnx").path
        let vocab = dir.appendingPathComponent("bpe.vocab").path
        guard FileManager.default.fileExists(atPath: model),
              FileManager.default.fileExists(atPath: vocab) else {
            logger.error("punct create: model files missing"); return nil
        }
        var err = [CChar](repeating: 0, count: 1024)
        guard let h = sherpa_create_punct(model, vocab, &err, Int32(err.count)) else {
            logger.error("sherpa_create_punct failed: \(String(cString: err), privacy: .public)")
            return nil
        }
        return PunctuationBridge(handle: h)
    }

    /// Add punctuation + restore casing for one text chunk. Returns the input unchanged on failure.
    ///
    /// The model was trained on lowercase ASR output and performs truecasing from there — so it is a
    /// no-op on ALL-CAPS input (it reads everything as already-capitalized). The streaming zipformer
    /// emits ALL-CAPS English, so we lowercase first; the model then restores sentence/proper-noun
    /// casing and inserts punctuation.
    func addPunct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let input = text.lowercased()
        // Casing/punctuation only inserts a handful of bytes; size generously off the input length.
        var out = [CChar](repeating: 0, count: max(8192, input.utf8.count * 2 + 64))
        let n = sherpa_punct_add(handle, input, &out, Int32(out.count))
        return n >= 0 ? String(cString: out) : text
    }

    deinit { sherpa_punct_destroy(handle) }
}

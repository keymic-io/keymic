import CSherpaOnnx
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SpeakerDiarizationBridge")

/// Thin wrapper over the sherpa-onnx offline speaker-diarization C API (reached via the
/// dlopen'd runtime). `create` requires the runtime dylibs loaded and the diarization models
/// downloaded. `process` runs the whole clip at once (offline) and returns speaker-tagged
/// intervals sorted by start time. Heavy/synchronous — call off the main actor.
final class SpeakerDiarizationBridge {
    /// Clustering distance threshold for auto speaker-count estimation. Tunable; 0.5 is the
    /// sherpa-onnx default starting point for campplus embeddings.
    private static let clusteringThreshold: Float = 0.5
    private static let maxSegments = 4096

    private let segModel: String
    private let embeddingModel: String

    private init(segModel: String, embeddingModel: String) {
        self.segModel = segModel
        self.embeddingModel = embeddingModel
    }

    /// Returns nil if the runtime isn't loadable or the diarization models are missing.
    static func create() -> SpeakerDiarizationBridge? {
        guard ONNXRuntimeLoader.shared.loadIfReady() else {
            logger.error("diarization create: runtime not loaded"); return nil
        }
        let dir = OnnxStores.diarization.destDir
        let seg = dir.appendingPathComponent("segmentation.onnx").path
        let emb = dir.appendingPathComponent("embedding.onnx").path
        guard FileManager.default.fileExists(atPath: seg),
              FileManager.default.fileExists(atPath: emb) else {
            logger.error("diarization create: model files missing"); return nil
        }
        return SpeakerDiarizationBridge(segModel: seg, embeddingModel: emb)
    }

    /// Run diarization over 16 kHz mono samples. Empty result on failure.
    func process(_ samples: [Float]) -> [DiarizationInterval] {
        guard !samples.isEmpty else { return [] }
        var starts = [Float](repeating: 0, count: Self.maxSegments)
        var ends = [Float](repeating: 0, count: Self.maxSegments)
        var speakers = [Int32](repeating: 0, count: Self.maxSegments)
        var err = [CChar](repeating: 0, count: 1024)

        let count = samples.withUnsafeBufferPointer { buf -> Int32 in
            sherpa_diarize(segModel, embeddingModel, Self.clusteringThreshold,
                           buf.baseAddress, Int32(buf.count),
                           &starts, &ends, &speakers, Int32(Self.maxSegments),
                           &err, Int32(err.count))
        }
        guard count >= 0 else {
            logger.error("sherpa_diarize failed: \(String(cString: err), privacy: .public)")
            return []
        }
        return (0..<Int(count)).map {
            DiarizationInterval(start: Double(starts[$0]), end: Double(ends[$0]), speaker: Int(speakers[$0]))
        }
    }
}

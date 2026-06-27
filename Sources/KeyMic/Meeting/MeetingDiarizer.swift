import Foundation
import os

/// Runs offline speaker diarization for a finished meeting: reads the retained system-audio WAV,
/// clusters remote speakers off the main actor, applies "对方 N" labels to the remote transcript
/// segments via `TranscriptStore` on the main actor, drives `diarizationState`, and deletes the
/// WAV on success. A missing model or any failure degrades gracefully (segments keep plain "对方").
@MainActor
final class MeetingDiarizer {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "MeetingDiarizer")
    private let store: TranscriptStore

    init(store: TranscriptStore) { self.store = store }

    /// Kick the background diarization job for a finished session. No-op (state stays "none")
    /// when there is no remote audio or the models/runtime aren't available.
    ///
    /// `wavStartOffset` is the session-relative time (seconds) of the WAV's first sample (≈ the
    /// system-audio capture-startup latency). The sherpa diarizer reports intervals relative to the
    /// WAV (t=0 = first sample), while transcript segment offsets are session-relative, so the two
    /// clocks differ by exactly this much — we shift the intervals forward before assignment.
    func diarize(sessionID: UUID, wavStartOffset: TimeInterval = 0) {
        let wav = MeetingAudioRecorder.url(for: sessionID)
        guard FileManager.default.fileExists(atPath: wav.path) else {
            Self.logger.info("diarize: no remote WAV; skipping"); return
        }
        let offsets = store.remoteSegments(for: sessionID)
        guard !offsets.isEmpty else {
            Self.logger.info("diarize: no remote segments; skipping")
            try? FileManager.default.removeItem(at: wav)
            return
        }
        guard let bridge = SpeakerDiarizationBridge.create() else {
            Self.logger.info("diarize: models/runtime unavailable; skipping")
            return   // state stays "none"; WAV kept so a later run could pick it up
        }

        store.setDiarizationState("processing", for: sessionID)

        Task.detached(priority: .utility) {
            let samples = Self.readWavSamples(wav)
            let intervals = bridge.process(samples)
            await MainActor.run {
                if intervals.isEmpty {
                    Self.logger.error("diarize: empty result; marking failed")
                    self.store.setDiarizationState("failed", for: sessionID)
                    return   // keep WAV for diagnosis
                }
                // Shift WAV-relative intervals onto session-relative time so they line up with the
                // transcript segment offsets the assignment matches against.
                let aligned = intervals.map {
                    DiarizationInterval(start: $0.start + wavStartOffset,
                                        end: $0.end + wavStartOffset,
                                        speaker: $0.speaker)
                }
                let assigned = SpeakerAssignment.assign(segmentOffsets: offsets, intervals: aligned)
                let labels = assigned.mapValues { MeetingHistoryFormatter.remoteSpeakerLabel($0) }
                self.store.setSpeakerLabels(labels, for: sessionID)
                self.store.setDiarizationState("done", for: sessionID)
                try? FileManager.default.removeItem(at: wav)
                Self.logger.info("diarize: done, \(Set(assigned.values).count, privacy: .public) speakers")
            }
        }
    }

    /// Decode a 16 kHz mono 16-bit PCM WAV (as written by `MeetingAudioRecorder`) into Float
    /// samples in [-1, 1]. Returns empty on a malformed/short file.
    nonisolated static func readWavSamples(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return [] }
        let body = data.subdata(in: 44..<data.count)
        let sampleCount = body.count / 2
        guard sampleCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: sampleCount)
        body.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let lo = UInt16(raw[i * 2]); let hi = UInt16(raw[i * 2 + 1])
                let s = Int16(bitPattern: lo | (hi << 8))
                out[i] = Float(s) / 32767.0
            }
        }
        return out
    }
}

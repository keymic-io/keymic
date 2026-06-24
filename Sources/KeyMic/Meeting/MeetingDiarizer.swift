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

    /// WAV written by P2.1's recorder for this session (same path convention).
    static func audioURL(_ session: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyMic/meeting-audio", isDirectory: true)
            .appendingPathComponent("\(session.uuidString).wav")
    }

    /// Kick the background diarization job for a finished session. No-op (state stays "none")
    /// when there is no remote audio or the models/runtime aren't available.
    func diarize(sessionID: UUID) {
        let wav = Self.audioURL(sessionID)
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
                let assigned = SpeakerAssignment.assign(segmentOffsets: offsets, intervals: intervals)
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

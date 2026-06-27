import Foundation

/// Streams 16 kHz mono Float samples to a 16-bit PCM WAV file on disk. Used to retain the
/// system-audio (remote) channel during a meeting so P2.2 can run offline speaker diarization
/// over it. Mic audio is single-speaker ("我") and is never recorded. The file is consumed and
/// deleted by the diarization job (P2.2); this type only writes and finalizes it.
final class MeetingAudioRecorder {
    /// Single source of truth for the retained system-audio WAV location. The writer (this type),
    /// the diarization reader (`MeetingDiarizer`), and the launch orphan-sweep (`AppDelegate`) all
    /// resolve the path through here so the convention can never drift between producer and consumer.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyMic/meeting-audio", isDirectory: true)
    }

    static func url(for session: UUID) -> URL {
        directory.appendingPathComponent("\(session.uuidString).wav")
    }

    let fileURL: URL
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private var finished = false
    private let lock = NSLock()

    /// Opens `url` for writing (creating parent dirs) and emits a WAV header with placeholder
    /// sizes. Returns nil if the file cannot be created.
    init?(url: URL, sampleRate: Int = 16000) {
        self.fileURL = url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        h.write(Self.header(sampleRate: UInt32(sampleRate), dataBytes: 0))
    }

    /// Convert to clamped 16-bit little-endian PCM and append. No-op after `finish()`.
    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !samples.isEmpty else { return }
        var bytes = [UInt8](); bytes.reserveCapacity(samples.count * 2)
        for f in samples {
            let clamped = max(Float(-1), min(Float(1), f))
            let u = UInt16(bitPattern: Int16(clamped * 32767))
            bytes.append(UInt8(u & 0xff))
            bytes.append(UInt8(u >> 8))
        }
        handle.write(Data(bytes))
        dataBytes += UInt32(bytes.count)
    }

    /// Patch the RIFF/data chunk sizes and close. Idempotent.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        try? handle.seek(toOffset: 4)
        handle.write(Self.u32le(36 + dataBytes))   // RIFF chunk size
        try? handle.seek(toOffset: 40)
        handle.write(Self.u32le(dataBytes))         // data chunk size
        try? handle.close()
    }

    private static func u32le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
    private static func u16le(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }

    private static func header(sampleRate: UInt32, dataBytes: UInt32) -> Data {
        var d = Data()
        d.append(Data("RIFF".utf8))
        d.append(u32le(36 + dataBytes))
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8))
        d.append(u32le(16))                  // PCM fmt chunk size
        d.append(u16le(1))                   // audio format = PCM
        d.append(u16le(1))                   // mono
        d.append(u32le(sampleRate))
        d.append(u32le(sampleRate * 2))      // byte rate = rate * channels * bytesPerSample
        d.append(u16le(2))                   // block align = channels * bytesPerSample
        d.append(u16le(16))                  // bits per sample
        d.append(Data("data".utf8))
        d.append(u32le(dataBytes))
        return d
    }
}

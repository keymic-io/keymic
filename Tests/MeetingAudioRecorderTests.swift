import Foundation

@main
struct MeetingAudioRecorderTests {
    static func main() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keymic-rec-\(ProcessInfo.processInfo.globallyUniqueString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let rec = MeetingAudioRecorder(url: tmp, sampleRate: 16000) else {
            fatalError("recorder init failed")
        }
        // 1.0 → 32767, -1.0 → -32767, 0 → 0, 0.5 → 16383 (truncated), clamp 2.0 → 32767
        rec.append([1.0, -1.0, 0.0, 0.5, 2.0])
        rec.finish()
        rec.finish()   // idempotent

        let data = try! Data(contentsOf: tmp)
        // Header is 44 bytes + 5 samples * 2 bytes = 54 bytes total.
        assert(data.count == 54, "expected 54 bytes, got \(data.count)")

        func str(_ r: Range<Int>) -> String { String(decoding: data[r], as: UTF8.self) }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | UInt32(data[off+1]) << 8 | UInt32(data[off+2]) << 16 | UInt32(data[off+3]) << 24
        }
        func u16(_ off: Int) -> UInt16 { UInt16(data[off]) | UInt16(data[off+1]) << 8 }
        func s16(_ off: Int) -> Int16 { Int16(bitPattern: u16(off)) }

        assert(str(0..<4) == "RIFF", "RIFF tag")
        assert(u32(4) == 36 + 10, "RIFF size = 36 + dataBytes(10)")
        assert(str(8..<12) == "WAVE", "WAVE tag")
        assert(str(12..<16) == "fmt ", "fmt tag")
        assert(u32(16) == 16, "fmt chunk size")
        assert(u16(20) == 1, "PCM format")
        assert(u16(22) == 1, "mono")
        assert(u32(24) == 16000, "sample rate")
        assert(u32(28) == 32000, "byte rate = 16000*1*2")
        assert(u16(32) == 2, "block align")
        assert(u16(34) == 16, "bits per sample")
        assert(str(36..<40) == "data", "data tag")
        assert(u32(40) == 10, "data size = 5 samples * 2 bytes")

        assert(s16(44) == 32767, "1.0 → 32767")
        assert(s16(46) == -32767, "-1.0 → -32767")
        assert(s16(48) == 0, "0.0 → 0")
        assert(s16(50) == 16383, "0.5 → 16383 (truncated)")
        assert(s16(52) == 32767, "2.0 clamped → 32767")

        print("MeetingAudioRecorderTests passed")
    }
}

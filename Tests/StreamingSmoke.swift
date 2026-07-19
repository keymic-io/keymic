import Foundation

@main
struct StreamingSmoke {
    static func main() {
        let runtimeReady = ONNXRuntimeLoader.shared.loadIfReady()
        guard runtimeReady else {
            FileHandle.standardError.write(Data("runtime not loaded — populate onnx-runtime/ first\n".utf8))
            exit(2)
        }
        let modelDir = OnnxStores.streaming.destDir
        guard let bridge = StreamingASRBridge.create(modelDir: modelDir) else {
            FileHandle.standardError.write(Data("create failed — populate streaming model first\n".utf8))
            exit(3)
        }
        let wavPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/fixtures/zh.wav"
        let samples = Self.readWav16kMonoFloat(path: wavPath)
        guard !samples.isEmpty else {
            FileHandle.standardError.write(Data("could not read wav: \(wavPath)\n".utf8)); exit(4)
        }

        let chunk = 3200  // 0.2s @ 16k
        var i = 0
        var finals: [String] = []
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            bridge.accept(Array(samples[i..<end]))
            let partial = bridge.currentText()
            if !partial.isEmpty { print("partial: \(partial)") }
            if bridge.isEndpoint() {
                let f = bridge.currentText()
                if !f.isEmpty { finals.append(f); print("FINAL: \(f)") }
                bridge.reset()
            }
            i = end
        }
        // Tail flush: feed trailing silence to force the last endpoint.
        bridge.accept([Float](repeating: 0, count: 16000))
        let tail = bridge.currentText()
        if !tail.isEmpty { finals.append(tail); print("FINAL(tail): \(tail)") }

        guard !finals.isEmpty else {
            FileHandle.standardError.write(Data("no final text produced\n".utf8)); exit(5)
        }
        print("StreamingSmoke passed — \(finals.count) final segment(s)")
    }

    /// Minimal 16-bit PCM WAV reader → Float32 [-1,1]. Assumes mono 16k (the fixture).
    static func readWav16kMonoFloat(path: String) -> [Float] {
        guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { return [] }
        // Locate "data" chunk; fall back to fixed 44-byte header if not found.
        var offset = 44
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var p = 12
            while p + 8 <= data.count {
                let id = String(bytes: data[p..<p+4], encoding: .ascii) ?? ""
                let sz = Int(bytes[p+4]) | Int(bytes[p+5])<<8 | Int(bytes[p+6])<<16 | Int(bytes[p+7])<<24
                if id == "data" { offset = p + 8; break }
                p += 8 + sz + (sz & 1)
            }
        }
        let pcm = data.subdata(in: offset..<data.count)
        var out = [Float](); out.reserveCapacity(pcm.count / 2)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s16 = raw.bindMemory(to: Int16.self)
            for v in s16 { out.append(Float(v) / 32768.0) }
        }
        return out
    }
}

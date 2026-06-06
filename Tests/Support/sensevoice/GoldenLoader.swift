import AVFoundation
import Foundation

/// Shared loaders for SenseVoice golden fixtures (WAV + JSON matrices).
/// Used by FbankExtractor (Task 3) and CTCDecoder (Task 5) standalone test runners.
enum GoldenLoader {
    /// Reads a 16 kHz mono PCM WAV into Float32 samples.
    /// The committed fixture is already 16k mono, so no resampling is needed.
    static func loadWav16k(_ path: String) -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            fatalError("GoldenLoader: cannot open WAV at \(path)")
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            fatalError("GoldenLoader: cannot allocate buffer for \(path)")
        }
        do {
            try file.read(into: buffer)
        } catch {
            fatalError("GoldenLoader: read failed for \(path): \(error)")
        }
        guard let channelData = buffer.floatChannelData else {
            fatalError("GoldenLoader: expected Float32 PCM in \(path)")
        }
        let n = Int(buffer.frameLength)
        // mono: take channel 0
        let ptr = channelData[0]
        return Array(UnsafeBufferPointer(start: ptr, count: n))
    }

    /// Decodes a JSON `[[Float]]` matrix.
    static func loadMatrix(_ path: String) -> [[Float]] {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            fatalError("GoldenLoader: cannot read JSON at \(path)")
        }
        guard let matrix = try? JSONDecoder().decode([[Float]].self, from: data) else {
            fatalError("GoldenLoader: cannot decode [[Float]] from \(path)")
        }
        return matrix
    }
}

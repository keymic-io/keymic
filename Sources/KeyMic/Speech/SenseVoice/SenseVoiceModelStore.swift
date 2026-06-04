import CoreML
import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SenseVoiceModelStore")

final class SenseVoiceModelStore {
    enum State: Equatable { case notDownloaded, downloading(Double), ready, failed(String) }

    private let baseDir: URL
    private(set) var state: State

    /// 默认 ~/Library/Application Support/KeyMic/models/
    init(baseDir: URL? = nil) {
        if let baseDir { self.baseDir = baseDir }
        else {
            let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.baseDir = appSup.appendingPathComponent("KeyMic/models", isDirectory: true)
        }
        let modelURL = self.baseDir.appendingPathComponent(SenseVoiceConfig.modelDirName)
        state = FileManager.default.fileExists(atPath: modelURL.path) ? .ready : .notDownloaded
    }

    var modelURL: URL { baseDir.appendingPathComponent(SenseVoiceConfig.modelDirName) }

    func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return got.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// 首次下载 → 校验 → 解压。完成 onState(.ready);任何失败 onState(.failed)。
    func ensureDownloaded(onState: @escaping (State) -> Void) {
        if case .ready = state { onState(.ready); return }
        guard let url = URL(string: SenseVoiceConfig.modelDownloadURLString) else { fail("bad download URL", onState); return }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, err in
            guard let self else { return }
            if let err { self.fail("download: \(err.localizedDescription)", onState); return }
            guard let tmp, self.verifySHA256(fileURL: tmp, expected: SenseVoiceConfig.modelSHA256) else {
                self.fail("sha256 mismatch", onState); return
            }
            let zip = self.baseDir.appendingPathComponent("model.mlmodelc.zip")
            try? FileManager.default.removeItem(at: zip)
            do {
                try FileManager.default.moveItem(at: tmp, to: zip)
                try self.unzip(zip, into: self.baseDir)
                self.state = .ready
                DispatchQueue.main.async { onState(.ready) }
            } catch { self.fail("unzip: \(error.localizedDescription)", onState) }
        }
        state = .downloading(0)
        task.resume()
    }

    /// 惰性加载 MLModel(主线程外调用)。失败返回 nil。
    func loadModel() -> MLModel? {
        guard case .ready = state else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        return try? MLModel(contentsOf: modelURL, configuration: cfg)
    }

    private func unzip(_ zip: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", zip.path, "-d", dir.path]
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "unzip", code: Int(p.terminationStatus)) }
    }

    private func fail(_ msg: String, _ onState: @escaping (State) -> Void) {
        logger.error("\(msg, privacy: .public)")
        state = .failed(msg)
        DispatchQueue.main.async { onState(.failed(msg)) }
    }
}

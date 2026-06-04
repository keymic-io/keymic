import CoreML
import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SenseVoiceModelStore")

final class SenseVoiceModelStore {
    enum State: Equatable { case notDownloaded, downloading(Double), ready, failed(String) }

    private let baseDir: URL

    // `state` is touched from both the caller thread and the URLSession background
    // completion thread, so all access goes through `lock`.
    private let lock = NSLock()
    private var _state: State
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }
    private func setState(_ s: State) {
        lock.lock(); _state = s; lock.unlock()
    }

    /// 默认 ~/Library/Application Support/KeyMic/models/
    init(baseDir: URL? = nil) {
        if let baseDir { self.baseDir = baseDir }
        else {
            let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.baseDir = appSup.appendingPathComponent("KeyMic/models", isDirectory: true)
        }
        let modelURL = self.baseDir.appendingPathComponent(SenseVoiceConfig.modelDirName)
        _state = FileManager.default.fileExists(atPath: modelURL.path) ? .ready : .notDownloaded
    }

    var modelURL: URL { baseDir.appendingPathComponent(SenseVoiceConfig.modelDirName) }

    func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return got.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// 首次下载 → 校验 → 解压。完成 onState(.ready);任何失败 onState(.failed)。
    ///
    /// 归档布局约定:下载的归档顶层条目必须正好是 `SenseVoiceConfig.modelDirName`
    /// (`SenseVoiceSmall.mlmodelc`),因为它会被解压进 `baseDir`,随后 `modelURL`
    /// 指向 `baseDir/<modelDirName>`。该约定待 Task 0 模型探针确认。
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
                // 解压成功后清理中间产物 zip。
                try? FileManager.default.removeItem(at: zip)
                self.setState(.ready)
                DispatchQueue.main.async { onState(.ready) }
            } catch { self.fail("unzip: \(error.localizedDescription)", onState) }
        }
        setState(.downloading(0))
        // TODO: 真实字节进度需要 URLSession delegate,延后到 settings 接线任务;现在先发一次 downloading 回调。
        DispatchQueue.main.async { onState(.downloading(0)) }
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
        setState(.failed(msg))
        DispatchQueue.main.async { onState(.failed(msg)) }
    }
}

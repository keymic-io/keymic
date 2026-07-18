import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "AssetStore")

/// 通用多文件资产下载 store。串行下载 bundle 的每个文件 → 逐文件 SHA256 → 全部成功后
/// 原子地把 staging 目录 move 到最终目录。State 机/锁/observer 模式同 SenseVoiceModelStore。
final class AssetStore {
    enum State: Equatable { case notDownloaded, downloading(Double), ready, failed(String) }

    let bundle: AssetBundle
    private let baseDir: URL
    private let lock = NSLock()
    private var _state: State
    private var stateObservers: [(State) -> Void] = []
    private var inFlight = false

    var destDir: URL { baseDir.appendingPathComponent(bundle.destDirName, isDirectory: true) }
    private var stagingDir: URL { baseDir.appendingPathComponent(bundle.destDirName + ".staging", isDirectory: true) }

    init(bundle: AssetBundle, baseDir: URL? = nil) {
        self.bundle = bundle
        let resolvedBase: URL
        if let baseDir { resolvedBase = baseDir }
        else {
            let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            resolvedBase = appSup.appendingPathComponent("KeyMic", isDirectory: true)
        }
        self.baseDir = resolvedBase
        // 清理遗留 staging(用局部路径,避免在所有 stored property 初始化前访问 self 的计算属性)。
        let staging = resolvedBase.appendingPathComponent(bundle.destDirName + ".staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        // ready 判定:所有文件都已存在于 destDir。
        let dest = resolvedBase.appendingPathComponent(bundle.destDirName, isDirectory: true)
        let allThere = bundle.files.allSatisfy {
            FileManager.default.fileExists(atPath: dest.appendingPathComponent($0.relPath).path)
        }
        _state = allThere ? .ready : .notDownloaded
    }

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    private func setState(_ s: State) {
        lock.lock(); _state = s; let obs = stateObservers; lock.unlock()
        guard !obs.isEmpty else { return }
        DispatchQueue.main.async { obs.forEach { $0(s) } }
    }

    func addStateObserver(_ observer: @escaping (State) -> Void) {
        lock.lock(); stateObservers.append(observer); lock.unlock()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return AssetStore.sha256Hex(data).caseInsensitiveCompare(expected) == .orderedSame
    }

    /// 单飞下载全部文件。完成 onState(.ready);任一失败 onState(.failed)。
    func ensureDownloaded(onState: @escaping (State) -> Void) {
        lock.lock()
        switch _state {
        case .ready: lock.unlock(); DispatchQueue.main.async { onState(.ready) }; return
        case .downloading: lock.unlock(); return
        case .notDownloaded, .failed: break
        }
        if inFlight { lock.unlock(); return }
        inFlight = true
        _state = .downloading(0)
        lock.unlock()
        DispatchQueue.main.async { onState(.downloading(0)) }

        // 后台串行下载,SHA256 + 放置全部 off-main。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.runDownload(onState: onState)
        }
    }

    /// Download `file.url`, falling back to each mirror in order on failure (e.g. HF blocked →
    /// ModelScope). Returns the first successful body plus the URL it came from, or throws the
    /// last error if all fail.
    static func downloadWithFallback(_ file: AssetFile) throws -> (data: Data, url: URL) {
        var lastError: Error = NSError(domain: "AssetStore", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "no source URLs"])
        for url in [file.url] + file.mirrors {
            do { return (try Data(contentsOf: url), url) }
            catch { lastError = error }
        }
        throw lastError
    }

    /// Coarse source label for telemetry, derived from a URL host. Content-free.
    static func telemetrySource(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("huggingface") { return "huggingface" }
        if host.contains("modelscope") { return "modelscope" }
        if host.contains("github") { return "github" }
        return "other"
    }

    private func runDownload(onState: @escaping (State) -> Void) {
        defer { lock.lock(); inFlight = false; lock.unlock() }
        dlStart = Date()
        dlSource = Self.telemetrySource(for: bundle.files.first?.url ?? URL(fileURLWithPath: "/"))
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        do { try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true) }
        catch { return fail("staging mkdir: \(error.localizedDescription)", onState) }

        let total = bundle.files.count
        for (i, file) in bundle.files.enumerated() {
            let dst = stagingDir.appendingPathComponent(file.relPath)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                let result = try Self.downloadWithFallback(file)   // 主源失败→按序试镜像;file:// 与 https 均可
                dlSource = Self.telemetrySource(for: result.url)
                try result.data.write(to: dst)
            } catch {
                try? fm.removeItem(at: stagingDir)
                return fail("download \(file.relPath): \(error.localizedDescription)", onState)
            }
            guard verifySHA256(fileURL: dst, expected: file.sha256) else {
                try? fm.removeItem(at: stagingDir)
                return fail("sha256 mismatch: \(file.relPath)", onState)
            }
            let frac = Double(i + 1) / Double(total)
            setState(.downloading(frac))
            DispatchQueue.main.async { onState(.downloading(frac)) }
        }

        // 全部校验通过 → 原子换入 destDir。
        do {
            try? fm.removeItem(at: destDir)
            try fm.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stagingDir, to: destDir)
            setState(.ready)
            emitModelDownload(result: "success", errorKind: nil)
            DispatchQueue.main.async { onState(.ready) }
        } catch {
            try? fm.removeItem(at: stagingDir)
            fail("place: \(error.localizedDescription)", onState)
        }
    }

    /// Start time + winning source for the in-flight download, for `model_download` telemetry.
    private var dlStart: Date?
    private var dlSource = "other"

    private func emitModelDownload(result: String, errorKind: String?) {
        let durationMs = dlStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        TelemetryService.shared.modelDownload(
            model: bundle.destDirName, result: result, durationMs: durationMs,
            source: dlSource, errorKind: errorKind)
    }

    private func fail(_ msg: String, _ onState: @escaping (State) -> Void) {
        logger.error("\(msg, privacy: .public)")
        // Coarse, content-free error kind from the code-controlled msg prefix (never a URL/path).
        let kind: String
        if msg.hasPrefix("sha256") { kind = "sha256Mismatch" }
        else if msg.hasPrefix("download") { kind = "network" }
        else { kind = "filesystem" }
        emitModelDownload(result: "failed", errorKind: kind)
        setState(.failed(msg))
        DispatchQueue.main.async { onState(.failed(msg)) }
    }
}

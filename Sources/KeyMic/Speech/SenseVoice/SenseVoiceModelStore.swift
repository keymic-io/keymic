import CoreML
import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SenseVoiceModelStore")

final class SenseVoiceModelStore {
    enum State: Equatable { case notDownloaded, downloading(Double), ready, failed(String) }

    /// App-wide store rooted at the default Application Support path. AppDelegate's engine
    /// factory and the Settings download button share this instance so `state` stays consistent.
    static let shared = SenseVoiceModelStore()

    private let baseDir: URL

    // `state` is touched from both the caller thread and the URLSession background
    // completion thread, so all access goes through `lock`.
    private let lock = NSLock()
    private var _state: State
    /// The 432 MB `MLModel` is cached after the first successful load so toggling SenseVoice
    /// off/on (or re-deciding the engine on every `UserDefaults` change) does not re-pay the
    /// heavy disk read. Guarded by `lock`.
    private var cachedModel: MLModel?

    // Retained for the lifetime of the store so the delegate (and its in-flight
    // download) is not deallocated mid-transfer. Created lazily on first download.
    // Guarded by `lock`.
    private var downloadSession: URLSession?
    private var downloadDelegate: DownloadDelegate?
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

        // Delegate-based download so we can stream real byte progress. The delegate's
        // `didFinishDownloadingTo` runs on `delegateQueue` (a dedicated *background*
        // OperationQueue below) — that is where the heavy SHA256 verify + unzip happen,
        // keeping them off the main thread (event-tap stall hazard). Only `onState`
        // hops to main.
        let delegate = DownloadDelegate(store: self, onState: onState)
        let queue = OperationQueue()
        queue.name = "io.keymic.app.sensevoice.download"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)

        // Retain the session + delegate for the duration of the transfer.
        lock.lock()
        downloadSession = session
        downloadDelegate = delegate
        lock.unlock()

        setState(.downloading(0))
        DispatchQueue.main.async { onState(.downloading(0)) }
        session.downloadTask(with: url).resume()
    }

    // MARK: - Delegate callbacks (invoked on the session's background delegateQueue)

    /// Real byte progress from the download delegate. Emitted per URLSession callback
    /// (URLSession already batches these); we update `_state` and hop `onState` to main.
    fileprivate func handleProgress(totalBytesWritten: Int64,
                                    totalBytesExpectedToWrite: Int64,
                                    onState: @escaping (State) -> Void) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        setState(.downloading(fraction))
        DispatchQueue.main.async { onState(.downloading(fraction)) }
    }

    /// Finish handler — runs on the background delegateQueue, so the SHA256 verify
    /// (hashing 432 MB) and `ditto` unzip stay off the main thread.
    fileprivate func handleFinishedDownload(tempURL: URL, onState: @escaping (State) -> Void) {
        defer { teardownSession() }
        guard verifySHA256(fileURL: tempURL, expected: SenseVoiceConfig.modelSHA256) else {
            fail("sha256 mismatch", onState); return
        }
        let zip = baseDir.appendingPathComponent("model.mlmodelc.zip")
        try? FileManager.default.removeItem(at: zip)
        do {
            try FileManager.default.moveItem(at: tempURL, to: zip)
            try extractArchive(zip, into: baseDir)
            // 解压成功后清理中间产物 zip。
            try? FileManager.default.removeItem(at: zip)
            setState(.ready)
            DispatchQueue.main.async { onState(.ready) }
        } catch { fail("unzip: \(error.localizedDescription)", onState) }
    }

    /// Transport-level failure handler — runs on the background delegateQueue.
    fileprivate func handleDownloadError(_ error: Error, onState: @escaping (State) -> Void) {
        defer { teardownSession() }
        fail("download: \(error.localizedDescription)", onState)
    }

    private func teardownSession() {
        lock.lock()
        let session = downloadSession
        downloadSession = nil
        downloadDelegate = nil
        lock.unlock()
        // Let in-flight delegate callbacks drain, then release the operation queue.
        session?.finishTasksAndInvalidate()
    }

    /// 惰性加载 MLModel(主线程外调用)。失败返回 nil。
    ///
    /// 首次加载约 432 MB,耗时数百毫秒;**必须在主线程外调用**(否则会卡住 event-tap
    /// 运行循环触发系统级键鼠冻结)。加载结果缓存,后续切换无需再读盘。
    /// `MLModel(contentsOf:)` 本身在 `lock` 之外执行,避免持锁期间承担重 I/O。
    func loadModel() -> MLModel? {
        lock.lock()
        let s = _state
        let cached = cachedModel
        lock.unlock()
        guard case .ready = s else { return nil }
        if let cached { return cached }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try? MLModel(contentsOf: modelURL, configuration: cfg)
        if let m {
            lock.lock()
            cachedModel = m
            lock.unlock()
        }
        return m
    }

    /// `ditto -xk --sequesterRsrc` is more robust than `unzip` for the `.mlmodelc`
    /// bundle directory + macOS resource-fork/metadata. ditto returns non-zero on failure.
    private func extractArchive(_ zip: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-xk", "--sequesterRsrc", zip.path, dir.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "ditto", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ditto failed: \(msg)"])
        }
    }

    private func fail(_ msg: String, _ onState: @escaping (State) -> Void) {
        logger.error("\(msg, privacy: .public)")
        setState(.failed(msg))
        DispatchQueue.main.async { onState(.failed(msg)) }
    }
}

// MARK: - URLSession download delegate

/// Bridges `URLSessionDownloadDelegate` callbacks back into the store. Lives on the
/// session's background `delegateQueue`, so it never touches the main thread except via
/// the store's `onState` hops. Retained by the store (`downloadDelegate`) for the
/// transfer's lifetime.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var store: SenseVoiceModelStore?
    private let onState: (SenseVoiceModelStore.State) -> Void

    init(store: SenseVoiceModelStore, onState: @escaping (SenseVoiceModelStore.State) -> Void) {
        self.store = store
        self.onState = onState
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        store?.handleProgress(totalBytesWritten: totalBytesWritten,
                              totalBytesExpectedToWrite: totalBytesExpectedToWrite,
                              onState: onState)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is a temp file that is removed once this callback returns, so the
        // verify + move + unzip must complete synchronously here (we are already on the
        // background delegateQueue, so this is safe and off-main).
        store?.handleFinishedDownload(tempURL: location, onState: onState)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // `didFinishDownloadingTo` already handled the success path; only report a
        // transport-level error here.
        if let error { store?.handleDownloadError(error, onState: onState) }
    }
}

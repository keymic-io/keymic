import CSherpaOnnx
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "ONNXRuntimeLoader")

/// 确保 runtime dylib 已下载 → dlopen。`isLoaded` 供工厂判断 ONNX 引擎是否可用。
/// 句柄常驻进程生命周期(dlopen 一次)。
final class ONNXRuntimeLoader {
    static let shared = ONNXRuntimeLoader()
    let store = AssetStore(bundle: VoiceModelCatalog.runtime)

    private let lock = NSLock()
    private var _loaded = false
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return _loaded }

    /// 若 runtime 已就绪则 dlopen(off-main 安全;dlopen 本身轻)。返回是否成功。
    @discardableResult
    func loadIfReady() -> Bool {
        lock.lock(); if _loaded { lock.unlock(); return true }; lock.unlock()
        guard store.state == .ready else { return false }
        var err = [CChar](repeating: 0, count: 1024)
        let rc = sherpa_load(store.destDir.path, &err, Int32(err.count))
        if rc == 0 {
            lock.lock(); _loaded = true; lock.unlock()
            logger.info("sherpa runtime loaded")
            return true
        }
        logger.error("sherpa_load failed: \(String(cString: err), privacy: .public)")
        return false
    }

    /// 触发 runtime 下载(若未就绪)。
    func ensureDownloaded(onState: @escaping (AssetStore.State) -> Void) {
        store.ensureDownloaded(onState: onState)
    }
}

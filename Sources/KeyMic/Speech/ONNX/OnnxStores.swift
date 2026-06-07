import Foundation

/// 进程级共享的 ONNX 模型下载 store。AppDelegate(引擎决策)与设置下载控制器共用同一实例,
/// 保证下载进度/就绪状态在 UI 与引擎间一致。runtime store 已是单例(`ONNXRuntimeLoader.shared.store`)。
enum OnnxStores {
    static let model = AssetStore(bundle: VoiceModelCatalog.funasrNano)
}

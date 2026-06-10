import AVFoundation
import CSherpaOnnx
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "ONNXSpeechEngine")

/// sherpa-onnx Fun-ASR-Nano (AR) 引擎。离线非流式:录音结束后整段解码,只出 final,无 partial(D5)。
/// 会话生命周期镜像 `SenseVoiceSpeechEngine`:本引擎持有 `AVAudioEngine` + tap,`AudioCapture16k`
/// 仅做 16k 累积。recognizer 句柄在 init 时传入(由 AppDelegate off-main 建好),引擎持有并在 deinit 释放。
@MainActor
final class ONNXSpeechEngine: SpeechEngineProtocol {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?
    var locale: Locale

    private let recognizer: UnsafeMutableRawPointer    // sherpa_create_funasr 句柄,引擎持有
    private let capture = AudioCapture16k()
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    /// 每次 startSession 自增;后台 final decode 捕获其值,新会话开始后丢弃旧结果(防 stale 注入)。
    private var sessionGeneration = 0

    /// recognizer 须由调用方(AppDelegate)在 off-main 用 sherpa_create_funasr 建好后传入。
    init(recognizer: UnsafeMutableRawPointer, locale: Locale) {
        self.recognizer = recognizer
        self.locale = locale
        capture.onAudioLevel = { [weak self] lvl in self?.onAudioLevel?(lvl) }
    }

    deinit { sherpa_destroy(recognizer) }

    func startSession() throws -> VoiceSession {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else { throw VoiceError.microphoneAccessDenied(status) }

        // Self-heal: a second entry point (e.g. the selected-text editor bypassing the
        // session host) may still have our tap installed — installing twice throws an
        // Obj-C NSException and crashes. Mirror SpeechAnalyzerSpeechEngine.startSession.
        teardown()
        sessionGeneration &+= 1
        capture.reset()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.capture.append(buf)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw VoiceError.audioEngineFailed(error.localizedDescription)
        }
        // 离线非流式:无 partial 计时器(D5)。
        return VoiceSession { [weak self] in self?.teardown() }
    }

    /// 松手:停采集,off-main 整段 sherpa 解码 → onFinalResult。generation 防 stale。
    func endAudio() {
        teardown()
        let samples = capture.snapshot()
        let gen = sessionGeneration
        guard !samples.isEmpty else {
            // 与正常路径保持异步语义:同步回调会在 onTriggerUp 的栈内跑完
            // handleFinal → cleanup,之后才设 grace timer,留下孤儿 timer 把
            // 触发键吞掉 2 秒。
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.sessionGeneration else { return }
                self.onFinalResult?("")
            }
            return
        }
        // 强持有 self:deinit 会 sherpa_destroy(recognizer),与在途 sherpa_decode
        // 并发即 native UAF。块为一次性,结束后释放引用,不构成泄漏环。
        DispatchQueue.global(qos: .userInitiated).async {
            // 输出缓冲按 6 分钟录音上限放大(对应 SherpaBridge.c 的 max_new_tokens)。
            var out = [CChar](repeating: 0, count: 32768)
            let rc = samples.withUnsafeBufferPointer { buf in
                sherpa_decode(self.recognizer, buf.baseAddress, Int32(buf.count), 16000, &out, Int32(out.count))
            }
            let text = String(cString: out)
            DispatchQueue.main.async {
                guard gen == self.sessionGeneration else { return }   // 丢弃 stale
                if rc == 0 { self.onFinalResult?(text) }
                else {
                    logger.error("onnx decode failed rc=\(rc)")
                    self.onError?("onnx decode failed (\(rc))"); self.onFinalResult?("")
                }
            }
        }
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }
}

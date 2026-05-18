import AVFoundation
import Speech
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SpeechEngine")

protocol SpeechAudioInputNodeing: AnyObject {
    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    )
    func removeTap(onBus bus: AVAudioNodeBus)
}

protocol SpeechAudioEngineing: AnyObject {
    var inputNode: SpeechAudioInputNodeing { get }
    var isRunning: Bool { get }
    func prepare()
    func start() throws
    func stop()
}

protocol SpeechRecognitionTasking: AnyObject {
    func cancel()
}

extension SFSpeechRecognitionTask: SpeechRecognitionTasking {}

private final class LiveSpeechAudioInputNode: SpeechAudioInputNodeing {
    private let node: AVAudioInputNode

    init(node: AVAudioInputNode) {
        self.node = node
    }

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        node.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        node.removeTap(onBus: bus)
    }
}

private final class LiveSpeechAudioEngine: SpeechAudioEngineing {
    private let engine = AVAudioEngine()
    private lazy var wrappedInputNode = LiveSpeechAudioInputNode(node: engine.inputNode)

    var inputNode: SpeechAudioInputNodeing { wrappedInputNode }
    var isRunning: Bool { engine.isRunning }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

final class SpeechEngine {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?

    private let audioEngineFactory: () -> SpeechAudioEngineing
    private let speechRecognizerAvailability: (SFSpeechRecognizer?) -> Bool
    private let startRecognitionTask:
        (
            SFSpeechRecognizer?, SFSpeechAudioBufferRecognitionRequest,
            @escaping (SFSpeechRecognitionResult?, Error?) -> Void
        ) -> SpeechRecognitionTasking?
    private let microphoneAuthorizationProbe: () -> AVAuthorizationStatus
    private var audioEngine: SpeechAudioEngineing?
    private var inputTapInstalled = false
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SpeechRecognitionTasking?
    private var speechRecognizer: SFSpeechRecognizer?
    private var firstBufferReceived = false
    private var audioWatchdog: DispatchWorkItem?
    // Bumped on every startRecording / cancel. The resultHandler captures
    // its own generation at creation and drops callbacks once the value
    // diverges, so a stale task can no longer pollute the live session.
    private var taskGeneration: UInt64 = 0

    var locale: Locale {
        didSet {
            speechRecognizer = SFSpeechRecognizer(locale: locale)
            if speechRecognizer == nil {
                onLocaleUnavailable?(
                    String(localized: "Speech recognition is not supported for \(locale.identifier). Please check that the language is downloaded in System Settings → General → Keyboard → Dictation.")
                )
            }
        }
    }

    init(
        locale: Locale = Locale.current,
        audioEngineFactory: @escaping () -> SpeechAudioEngineing = { LiveSpeechAudioEngine() },
        speechRecognizerAvailability: @escaping (SFSpeechRecognizer?) -> Bool = { $0?.isAvailable == true },
        startRecognitionTask: (
            (
                SFSpeechRecognizer?, SFSpeechAudioBufferRecognitionRequest,
                @escaping (SFSpeechRecognitionResult?, Error?) -> Void
            ) -> SpeechRecognitionTasking?
        )? = nil,
        microphoneAuthorizationProbe: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }
    ) {
        self.locale = locale
        self.audioEngineFactory = audioEngineFactory
        self.speechRecognizerAvailability = speechRecognizerAvailability
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.startRecognitionTask =
            startRecognitionTask ?? { recognizer, request, handler in
                recognizer?.recognitionTask(with: request, resultHandler: handler)
            }
        self.microphoneAuthorizationProbe = microphoneAuthorizationProbe
    }

    // MARK: - Permissions

    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            if granted {
                                completion(true, nil)
                            } else {
                                completion(
                                    false,
                                    String(localized: "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
                                )
                            }
                        }
                    }
                case .denied, .restricted:
                    completion(
                        false,
                        String(localized: "Speech recognition denied.\nGrant in System Settings → Privacy & Security → Speech Recognition.")
                    )
                case .notDetermined:
                    completion(false, String(localized: "Speech recognition permission not determined."))
                @unknown default:
                    completion(false, String(localized: "Unknown speech recognition authorization status."))
                }
            }
        }
    }

    // MARK: - Recording

    /// Begin a new session. Throws `VoiceError.microphoneAccessDenied` if TCC
    /// status is anything other than `.authorized`. Throws
    /// `VoiceError.recognizerUnavailable` / `VoiceError.audioEngineFailed`
    /// for the matching failures. The returned `VoiceSession.cancel()`
    /// (or its deinit) tears down the recognition task + audio engine.
    func startSession() throws -> VoiceSession {
        let status = microphoneAuthorizationProbe()
        guard status == .authorized else {
            throw VoiceError.microphoneAccessDenied(status)
        }

        cleanupAudioSession()
        taskGeneration &+= 1
        let myGeneration = taskGeneration
        recognitionTask?.cancel()
        recognitionTask = nil
        firstBufferReceived = false

        guard speechRecognizerAvailability(speechRecognizer) else {
            throw VoiceError.recognizerUnavailable(locale.identifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) { request.addsPunctuation = true }
        recognitionRequest = request

        recognitionTask = startRecognitionTask(speechRecognizer, request) { [weak self] result, error in
            guard let self, self.taskGeneration == myGeneration else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal { self.onFinalResult?(text) } else { self.onPartialResult?(text) }
            }
            if let error { self.onError?(error.localizedDescription) }
        }

        let engine = audioEngineFactory()
        audioEngine = engine
        let inputNode = engine.inputNode
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        logger.info("startSession — input device: \(deviceName, privacy: .public)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            request.append(buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.firstBufferReceived else { return }
                self.firstBufferReceived = true
                self.audioWatchdog?.cancel()
                self.audioWatchdog = nil
            }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
            let rms = sqrtf(sum / Float(max(frameLength, 1)))
            let dB = 20 * log10(max(rms, 1e-6))
            let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
            DispatchQueue.main.async { self?.onAudioLevel?(normalized) }
        }
        inputTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // cleanup() nils recognitionTask but does NOT cancel it — order matters.
            recognitionTask?.cancel()
            cleanup()
            throw VoiceError.audioEngineFailed(error.localizedDescription)
        }

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.firstBufferReceived else { return }
            logger.error(
                "No audio frames in 800ms — Bluetooth SCO cold-start failure (device: \(deviceName, privacy: .public))")
            self.cleanup()
            self.onError?("麦克风未响应，请松开后稍候再试")
        }
        audioWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: watchdog)

        let sessionGeneration = myGeneration
        return VoiceSession { [weak self] in
            guard let self, self.taskGeneration == sessionGeneration else { return }
            self.endSession()
        }
    }

    /// End audio capture but let the recognition task drain to a final result.
    /// Called when the state machine transitions listening → transcribing.
    func endAudio() {
        cleanupAudioSession()
        recognitionRequest?.endAudio()
    }

    /// Abort everything: recognition task is canceled, audio teardown completes.
    /// Called by `VoiceSession.cancel()` / its deinit.
    private func endSession() {
        taskGeneration &+= 1
        recognitionTask?.cancel()
        cleanup()
    }

    private func cleanup() {
        cleanupAudioSession()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func cleanupAudioSession() {
        audioWatchdog?.cancel()
        audioWatchdog = nil
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }
        audioEngine = nil
    }
}

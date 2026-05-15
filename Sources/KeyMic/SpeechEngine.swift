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
        )? = nil
    ) {
        self.locale = locale
        self.audioEngineFactory = audioEngineFactory
        self.speechRecognizerAvailability = speechRecognizerAvailability
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.startRecognitionTask =
            startRecognitionTask ?? { recognizer, request, handler in
                recognizer?.recognitionTask(with: request, resultHandler: handler)
            }
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

    func startRecording() {
        cleanupAudioSession()
        taskGeneration &+= 1
        let myGeneration = taskGeneration
        recognitionTask?.cancel()
        recognitionTask = nil
        firstBufferReceived = false

        guard speechRecognizerAvailability(speechRecognizer) else {
            onError?(String(localized: "Speech recognizer not available for \(locale.identifier)"))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        recognitionTask = startRecognitionTask(speechRecognizer, request) { [weak self] result, error in
            // Drop callbacks from a task that has been superseded by a newer
            // startRecording or cancel — stale partials would otherwise
            // overwrite the live session and dismiss its overlay. Errors that
            // belong to the live task are surfaced as-is so real failures
            // (e.g. recognizer service crashes) reach the user.
            guard let self, self.taskGeneration == myGeneration else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.onFinalResult?(text)
                } else {
                    self.onPartialResult?(text)
                }
            }
            if let error {
                self.onError?(error.localizedDescription)
            }
        }

        let engine = audioEngineFactory()
        audioEngine = engine
        let inputNode = engine.inputNode

        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        logger.info("startRecording — input device: \(deviceName, privacy: .public)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            request.append(buffer)

            // Cancel watchdog on first real buffer (dispatched to main to stay on same queue).
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.firstBufferReceived else { return }
                self.firstBufferReceived = true
                self.audioWatchdog?.cancel()
                self.audioWatchdog = nil
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<n { sum += data[i] * data[i] }
                }
                let rms = sqrtf(sum / Float(max(n, 1)))
                logger.info(
                    "First audio buffer — device: \(deviceName, privacy: .public), frames: \(n, privacy: .public), RMS: \(rms, privacy: .public)"
                )
            }

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(max(frameLength, 1)))
            let dB = 20 * log10(max(rms, 1e-6))
            let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
            DispatchQueue.main.async {
                self?.onAudioLevel?(normalized)
            }
        }
        inputTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            recognitionTask?.cancel()
            onError?(String(localized: "Audio engine failed: \(error.localizedDescription)"))
            cleanup()
            return
        }

        // Watchdog: if no audio frame arrives within 800ms, the mic is stuck
        // (common with Bluetooth SCO cold-start). Tear down and notify the user.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.firstBufferReceived else { return }
            logger.error(
                "No audio frames in 800ms — Bluetooth SCO cold-start failure (device: \(deviceName, privacy: .public))")
            self.cleanup()
            self.onError?("麦克风未响应，请松开后稍候再试")
        }
        audioWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: watchdog)
    }

    func stopRecording() {
        cleanupAudioSession()
        recognitionRequest?.endAudio()
    }

    func cancel() {
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

import AVFoundation
import Foundation

private final class SpeechEngineTests {
    static func main() {
        testStartCreatesFreshEngineForEachRecording()
        testCancelRemovesTapAndStopsEngine()
        testStartFailureCancelsRecognitionTaskAndCleansUpAudioSession()
        testStartRecognitionTaskUsesCurrentRecognizerAfterLocaleChange()
        print("SpeechEngineTests passed")
    }

    private static func testStartCreatesFreshEngineForEachRecording() {
        let factory = FakeAudioEngineFactory()
        let engine = SpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in FakeRecognitionTask() }
        )

        engine.startRecording()
        engine.stopRecording()
        engine.startRecording()

        precondition(factory.engines.count == 2, "Expected a fresh audio engine for each recording session")
        precondition(factory.engines[0] !== factory.engines[1], "Expected recordings not to reuse AVAudioEngine instances")
        precondition(factory.engines[0].fakeInputNode.removeTapCalls == [0], "Expected first engine tap to be removed after stop")
        precondition(factory.engines[1].fakeInputNode.installTapCalls.count == 1, "Expected second engine to install one tap")
        precondition(factory.engines[1].fakeInputNode.installTapCalls[0].format == nil, "Expected tap format nil so AVFAudio chooses active input format")
    }

    private static func testCancelRemovesTapAndStopsEngine() {
        let factory = FakeAudioEngineFactory()
        let engine = SpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in FakeRecognitionTask() }
        )

        engine.startRecording()
        engine.cancel()

        let audioEngine = factory.engines[0]
        precondition(audioEngine.stopCalls == 1, "Expected cancel to stop the active audio engine")
        precondition(audioEngine.fakeInputNode.removeTapCalls == [0], "Expected cancel to remove the active input tap")
    }

    private static func testStartFailureCancelsRecognitionTaskAndCleansUpAudioSession() {
        let factory = FakeAudioEngineFactory(nextEngine: FakeAudioEngine(startBehavior: .throwAfterStarting))
        let recognitionTask = FakeRecognitionTask()
        let engine = SpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in recognitionTask }
        )

        engine.startRecording()

        let audioEngine = factory.engines[0]
        precondition(recognitionTask.cancelCalls == 1, "Expected failed engine start to cancel the recognition task")
        precondition(audioEngine.fakeInputNode.removeTapCalls == [0], "Expected failed engine start to remove the installed tap")
        precondition(audioEngine.stopCalls == 1, "Expected failed engine start to stop the engine during cleanup")
        precondition(audioEngine.isRunning == false, "Expected failed engine start cleanup to leave the engine stopped")
    }

    private static func testStartRecognitionTaskUsesCurrentRecognizerAfterLocaleChange() {
        let factory = FakeAudioEngineFactory()
        var observedLocales: [String] = []
        let engine = SpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { recognizer, _, _ in
                observedLocales.append(recognizer?.locale.identifier ?? "nil")
                return FakeRecognitionTask()
            }
        )

        engine.startRecording()
        engine.stopRecording()
        engine.locale = Locale(identifier: "ja_JP")
        engine.startRecording()

        precondition(observedLocales == ["en_US", "ja_JP"], "Expected recognition to use the current recognizer after locale changes")
    }
}

private final class FakeAudioEngineFactory {
    private let engineBuilder: () -> FakeAudioEngine
    private(set) var engines: [FakeAudioEngine] = []

    init(engineBuilder: @escaping () -> FakeAudioEngine = { FakeAudioEngine() }) {
        self.engineBuilder = engineBuilder
    }

    convenience init(nextEngine: FakeAudioEngine) {
        self.init(engineBuilder: { nextEngine })
    }

    func makeEngine() -> SpeechAudioEngineing {
        let engine = engineBuilder()
        engines.append(engine)
        return engine
    }
}

private final class FakeAudioEngine: SpeechAudioEngineing {
    enum StartBehavior {
        case succeed
        case throwAfterStarting
    }

    struct StartFailure: Error {}

    let fakeInputNode = FakeAudioInputNode()
    var inputNode: SpeechAudioInputNodeing { fakeInputNode }
    private(set) var isRunning = false
    private(set) var prepareCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private let startBehavior: StartBehavior

    init(startBehavior: StartBehavior = .succeed) {
        self.startBehavior = startBehavior
    }

    func prepare() {
        prepareCalls += 1
    }

    func start() throws {
        startCalls += 1
        isRunning = true
        if startBehavior == .throwAfterStarting {
            throw StartFailure()
        }
    }

    func stop() {
        stopCalls += 1
        isRunning = false
    }
}

private final class FakeAudioInputNode: SpeechAudioInputNodeing {
    struct InstallTapCall {
        let bus: AVAudioNodeBus
        let bufferSize: AVAudioFrameCount
        let format: AVAudioFormat?
    }

    private(set) var installTapCalls: [InstallTapCall] = []
    private(set) var removeTapCalls: [AVAudioNodeBus] = []

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        installTapCalls.append(InstallTapCall(bus: bus, bufferSize: bufferSize, format: format))
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        removeTapCalls.append(bus)
    }
}

private final class FakeRecognitionTask: SpeechRecognitionTasking {
    private(set) var cancelCalls = 0

    func cancel() {
        cancelCalls += 1
    }
}

@main
private enum TestRunner {
    static func main() {
        SpeechEngineTests.main()
    }
}

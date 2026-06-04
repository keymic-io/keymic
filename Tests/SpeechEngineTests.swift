import AVFoundation
import Foundation

@MainActor
private final class SpeechEngineTests {
    static func main() {
        testStartCreatesFreshEngineForEachRecording()
        testCancelRemovesTapAndStopsEngine()
        testStartFailureCancelsRecognitionTaskAndCleansUpAudioSession()
        testStartRecognitionTaskUsesCurrentRecognizerAfterLocaleChange()
        testStartSessionThrowsWhenMicDenied()
        testCancelingStaleSessionDoesNotTearDownNewSession()
        print("SpeechEngineTests passed")
    }

    private static func testStartCreatesFreshEngineForEachRecording() {
        let factory = FakeAudioEngineFactory()
        let engine = AppleSpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in FakeRecognitionTask() },
            microphoneAuthorizationProbe: { .authorized }
        )

        _ = try? engine.startSession()
        engine.endAudio()
        _ = try? engine.startSession()

        precondition(factory.engines.count == 2, "Expected a fresh audio engine for each startSession")
        precondition(factory.engines[0] !== factory.engines[1], "Expected startSession not to reuse AVAudioEngine instances")
        precondition(factory.engines[0].fakeInputNode.removeTapCalls == [0], "Expected first engine tap to be removed after stop")
        precondition(factory.engines[1].fakeInputNode.installTapCalls.count == 1, "Expected second engine to install one tap")
        precondition(factory.engines[1].fakeInputNode.installTapCalls[0].format == nil, "Expected tap format nil so AVFAudio chooses active input format")
    }

    private static func testCancelRemovesTapAndStopsEngine() {
        let factory = FakeAudioEngineFactory()
        let engine = AppleSpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in FakeRecognitionTask() },
            microphoneAuthorizationProbe: { .authorized }
        )

        let session = try? engine.startSession()
        session?.cancel()

        let audioEngine = factory.engines[0]
        precondition(audioEngine.stopCalls == 1, "Expected cancel to stop the active audio engine")
        precondition(audioEngine.fakeInputNode.removeTapCalls == [0], "Expected cancel to remove the active input tap")
    }

    private static func testStartFailureCancelsRecognitionTaskAndCleansUpAudioSession() {
        let factory = FakeAudioEngineFactory(nextEngine: FakeAudioEngine(startBehavior: .throwAfterStarting))
        let recognitionTask = FakeRecognitionTask()
        let engine = AppleSpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in recognitionTask },
            microphoneAuthorizationProbe: { .authorized }
        )

        do {
            _ = try engine.startSession()
        } catch {
            // expected throw — VoiceError.audioEngineFailed
        }

        let audioEngine = factory.engines[0]
        precondition(recognitionTask.cancelCalls == 1, "Expected failed engine start to cancel the recognition task")
        precondition(audioEngine.fakeInputNode.removeTapCalls == [0], "Expected failed engine start to remove the installed tap")
        precondition(audioEngine.stopCalls == 1, "Expected failed engine start to stop the engine during cleanup")
        precondition(audioEngine.isRunning == false, "Expected failed engine start cleanup to leave the engine stopped")
    }

    private static func testStartRecognitionTaskUsesCurrentRecognizerAfterLocaleChange() {
        let factory = FakeAudioEngineFactory()
        var observedLocales: [String] = []
        let engine = AppleSpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { recognizer, _, _ in
                observedLocales.append(recognizer?.locale.identifier ?? "nil")
                return FakeRecognitionTask()
            },
            microphoneAuthorizationProbe: { .authorized }
        )

        _ = try? engine.startSession()
        engine.endAudio()
        engine.locale = Locale(identifier: "ja_JP")
        _ = try? engine.startSession()

        precondition(observedLocales == ["en_US", "ja_JP"], "Expected recognition to use the current recognizer after locale changes")
    }

    private static func testCancelingStaleSessionDoesNotTearDownNewSession() {
        let factory = FakeAudioEngineFactory()
        let engine = AppleSpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in FakeRecognitionTask() },
            microphoneAuthorizationProbe: { .authorized }
        )

        // Step 1: Start first session (engine 1 created)
        let session1 = try? engine.startSession()
        precondition(factory.engines.count == 1, "Expected exactly one engine after first startSession")

        // Step 2: endAudio (simulates listening → transcribing: audio torn down, recognition still alive)
        engine.endAudio()

        // Step 3: Start second session (engine 2 created, generation bumped). Hold a strong
        // reference so that session2's deinit does not fire during this test.
        let session2 = try? engine.startSession()
        precondition(factory.engines.count == 2, "Expected a second engine after second startSession")

        let engine2 = factory.engines[1]

        // Step 4: Cancel the FIRST session (its closeHook should no-op due to generation mismatch)
        session1?.cancel()

        // Step 5: Engine 2 must still be alive
        precondition(engine2.stopCalls == 0, "Canceling stale session must not stop the new audio engine")
        precondition(engine2.fakeInputNode.removeTapCalls.isEmpty, "Canceling stale session must not remove tap from new engine")

        // Step 6: Engine 1 was already torn down by endAudio + startSession cleanup
        let engine1 = factory.engines[0]
        precondition(engine1.stopCalls >= 1, "Engine 1 should have been stopped during cleanup")

        // Keep session2 alive until assertions are complete so its deinit
        // does not fire early and tear down engine2 before we can check it.
        _ = session2
    }

    private static func testStartSessionThrowsWhenMicDenied() {
        let factory = FakeAudioEngineFactory()
        let engine = AppleSpeechEngine(
            locale: Locale(identifier: "en_US"),
            audioEngineFactory: factory.makeEngine,
            speechRecognizerAvailability: { _ in true },
            startRecognitionTask: { _, _, _ in FakeRecognitionTask() },
            microphoneAuthorizationProbe: { .denied }
        )

        do {
            _ = try engine.startSession()
            preconditionFailure("expected microphoneAccessDenied to throw")
        } catch let err as VoiceError {
            guard case .microphoneAccessDenied(let s) = err else {
                preconditionFailure("expected .microphoneAccessDenied, got \(err)")
            }
            precondition(s == .denied)
        } catch {
            preconditionFailure("expected VoiceError, got \(error)")
        }

        precondition(factory.engines.isEmpty, "audio engine must NOT be built when permission is denied")
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
    @MainActor
    static func main() {
        SpeechEngineTests.main()
    }
}

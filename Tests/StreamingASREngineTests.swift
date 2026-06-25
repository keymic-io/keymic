import Foundation

/// Scripted fake recognizer. Each `feed` on the engine triggers exactly one
/// `accept` (which advances the cursor) followed by `isEndpoint` + `currentText`
/// reads for that same step.
private final class FakeRecognizer: StreamingRecognizing {
    struct Step { let text: String; let endpoint: Bool }

    private let steps: [Step]
    private var cursor = -1
    private(set) var accepted: [[Float]] = []
    private(set) var resetCount = 0

    init(_ steps: [Step]) { self.steps = steps }

    func accept(_ samples: [Float], sampleRate: Int32) {
        accepted.append(samples)
        cursor += 1
    }
    private var current: Step { steps[min(max(cursor, 0), steps.count - 1)] }
    func currentText() -> String { current.text }
    func isEndpoint() -> Bool { current.endpoint }
    func reset() { resetCount += 1 }
}

@main
struct StreamingASREngineTests {
    /// Synchronous executor + deliver so the serial-queue / main-hop indirection
    /// runs inline and assertions are deterministic.
    private static func makeEngine(
        _ fake: FakeRecognizer,
        textTransform: ((String) -> String)? = nil,
        now: @escaping () -> TimeInterval
    ) -> StreamingASREngine {
        StreamingASREngine(
            source: 0,
            recognizer: fake,
            partialThrottle: 0.2,
            textTransform: textTransform,
            execute: { $0() },
            deliver: { $0() },
            now: now)
    }

    static func main() {
        testAcceptsChunks()
        testPartialThrottle()
        testEndpointEmitsSingleFinalAndResets()
        testIgnoresEmptyPartialAndFinal()
        testStopSuppressesLateCallbacks()
        testTextTransformAppliesToPartialAndFinal()
        testTextTransformRunsOncePerEmittedText()
        print("StreamingASREngineTests passed")
    }

    // The transform rewrites both emitted partial and emitted final text.
    static func testTextTransformAppliesToPartialAndFinal() {
        let fake = FakeRecognizer([
            .init(text: "hello world", endpoint: false),
            .init(text: "hello world how are you", endpoint: true),
        ])
        let engine = makeEngine(fake, textTransform: { "[" + $0 + "]" }) { 100 }
        var partials: [String] = []
        var finals: [String] = []
        engine.onPartial = { _, text in partials.append(text) }
        engine.onFinal = { _, text in finals.append(text) }

        engine.feed([1])   // partial
        engine.feed([1])   // endpoint → final

        assert(partials == ["[hello world]"], "partial transformed: \(partials)")
        assert(finals == ["[hello world how are you]"], "final transformed: \(finals)")
    }

    // Dedup/throttle gate the RAW text, so the transform runs only for actually-emitted text:
    // once for the throttled-but-distinct partial path here, not on every chunk.
    static func testTextTransformRunsOncePerEmittedText() {
        let fake = FakeRecognizer([
            .init(text: "abc", endpoint: false),   // t=0   → emit (transform #1)
            .init(text: "abc", endpoint: false),   // t=0.1 → duplicate raw → dropped, no transform
            .init(text: "abcd", endpoint: false),  // t=0.1 → throttled (< 200ms) → no transform
        ])
        var clock: TimeInterval = 0
        var transformCalls = 0
        let engine = makeEngine(fake, textTransform: { transformCalls += 1; return $0.uppercased() }) { clock }
        var partials: [String] = []
        engine.onPartial = { _, text in partials.append(text) }

        clock = 0;   engine.feed([1])
        clock = 0.1; engine.feed([1])
        clock = 0.1; engine.feed([1])

        assert(partials == ["ABC"], "only the first distinct partial emits: \(partials)")
        assert(transformCalls == 1, "transform runs once, not per chunk: \(transformCalls)")
    }

    // Audio chunks reach the recognizer on the engine path.
    static func testAcceptsChunks() {
        let fake = FakeRecognizer([.init(text: "", endpoint: false)])
        let engine = makeEngine(fake) { 0 }
        engine.feed([0.1, 0.2, 0.3])
        assert(fake.accepted.count == 1, "feed forwards one accept")
        assert(fake.accepted.first == [0.1, 0.2, 0.3], "samples forwarded verbatim")
    }

    // Partial text emits, then is throttled until the window elapses; identical text never re-emits.
    static func testPartialThrottle() {
        let fake = FakeRecognizer([
            .init(text: "你", endpoint: false),     // t=0   → emit
            .init(text: "你好", endpoint: false),    // t=0.1 → throttled (< 200ms)
            .init(text: "你好吗", endpoint: false),   // t=0.25 → emit
        ])
        var clock: TimeInterval = 0
        let engine = makeEngine(fake) { clock }
        var partials: [String] = []
        engine.onPartial = { _, text in partials.append(text) }

        clock = 0;    engine.feed([1])
        clock = 0.1;  engine.feed([1])
        clock = 0.25; engine.feed([1])

        assert(partials == ["你", "你好吗"], "throttled within window, emits after: \(partials)")
    }

    // Endpoint reads final text, emits exactly one onFinal, calls reset, and emits no partial for it.
    static func testEndpointEmitsSingleFinalAndResets() {
        let fake = FakeRecognizer([.init(text: "结束了", endpoint: true)])
        let engine = makeEngine(fake) { 0 }
        var finals: [String] = []
        var partials: [String] = []
        engine.onFinal = { _, text in finals.append(text) }
        engine.onPartial = { _, text in partials.append(text) }

        engine.feed([1])

        assert(finals == ["结束了"], "exactly one final with endpoint text: \(finals)")
        assert(partials.isEmpty, "endpoint must not emit a partial")
        assert(fake.resetCount == 1, "reset called once after final")
    }

    // Empty / whitespace-only partial and final strings are dropped.
    static func testIgnoresEmptyPartialAndFinal() {
        let fake = FakeRecognizer([
            .init(text: "   ", endpoint: false),
            .init(text: "", endpoint: true),
        ])
        let engine = makeEngine(fake) { 100 }
        var partials = 0, finals = 0
        engine.onPartial = { _, _ in partials += 1 }
        engine.onFinal = { _, _ in finals += 1 }

        engine.feed([1])
        engine.feed([1])

        assert(partials == 0, "whitespace partial dropped")
        assert(finals == 0, "empty final dropped")
        assert(fake.resetCount == 1, "endpoint still resets even when final text empty")
    }

    // After stop(), feeding produces no callbacks.
    static func testStopSuppressesLateCallbacks() {
        let fake = FakeRecognizer([
            .init(text: "迟到", endpoint: false),
            .init(text: "也迟到", endpoint: true),
        ])
        let engine = makeEngine(fake) { 100 }
        var partials = 0, finals = 0
        engine.onPartial = { _, _ in partials += 1 }
        engine.onFinal = { _, _ in finals += 1 }

        engine.stop()
        engine.feed([1])
        engine.feed([1])

        assert(partials == 0 && finals == 0, "no callbacks after stop")
    }
}

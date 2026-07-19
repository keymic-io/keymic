import Foundation

/// Minimal seam over one streaming recognizer so `StreamingASREngine` can be unit-tested
/// with a fake. Production conformer is `StreamingASRBridge` (one sherpa-onnx online stream).
protocol StreamingRecognizing: AnyObject {
    func accept(_ samples: [Float], sampleRate: Int32)
    func currentText() -> String
    func isEndpoint() -> Bool
    func reset()
}

/// Meeting-runtime wrapper around one streaming recognizer (one audio source/channel).
/// Owns a private serial queue because the recognizer is not thread-safe: `feed` accepts
/// audio, polls partial text (throttled), and on endpoint emits one final segment then resets.
/// `stop()` suppresses any further callbacks.
final class StreamingASREngine {
    /// (source, text) — partial (in-progress) hypothesis, throttled.
    var onPartial: ((Int, String) -> Void)?
    /// (source, text) — endpoint-final text. Emitted once per endpoint.
    var onFinal: ((Int, String) -> Void)?

    private let source: Int
    private let recognizer: StreamingRecognizing
    private let partialThrottle: TimeInterval
    private let execute: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private let now: () -> TimeInterval
    /// Optional text post-processing (e.g. English punctuation + truecasing), run on the engine's
    /// serial queue right before delivery. nil → raw recognizer text. Applied to every final
    /// segment, and to each partial only after the throttle/dedup gate (bounds model calls).
    private let textTransform: ((String) -> String)?

    private var stopped = false
    private var lastPartialAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastPartialText = ""

    init(
        source: Int,
        recognizer: StreamingRecognizing,
        partialThrottle: TimeInterval = 0.2,
        textTransform: ((String) -> String)? = nil,
        execute: ((@escaping () -> Void) -> Void)? = nil,
        deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.recognizer = recognizer
        self.partialThrottle = partialThrottle
        self.textTransform = textTransform
        self.deliver = deliver
        self.now = now
        if let execute {
            self.execute = execute
        } else {
            let queue = DispatchQueue(label: "io.keymic.meeting.asr.\(source)", qos: .userInitiated)
            self.execute = { queue.async(execute: $0) }
        }
    }

    func feed(_ samples: [Float]) {
        execute { [weak self] in
            guard let self, !self.stopped else { return }
            self.recognizer.accept(samples, sampleRate: 16000)
            guard !self.stopped else { return }

            if self.recognizer.isEndpoint() {
                let raw = self.recognizer.currentText()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.recognizer.reset()
                self.lastPartialText = ""
                guard !raw.isEmpty else { return }
                let text = self.textTransform.map { $0(raw) } ?? raw
                self.deliver { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.onFinal?(self.source, text)
                }
                return
            }

            // Dedup + throttle on the RAW hypothesis so the transform runs at most once per
            // throttle window, not on every audio chunk.
            let raw = self.recognizer.currentText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != self.lastPartialText else { return }
            let t = self.now()
            guard t - self.lastPartialAt >= self.partialThrottle else { return }
            self.lastPartialAt = t
            self.lastPartialText = raw
            let text = self.textTransform.map { $0(raw) } ?? raw
            self.deliver { [weak self] in
                guard let self, !self.stopped else { return }
                self.onPartial?(self.source, text)
            }
        }
    }

    /// Suppress all further callbacks. Safe to call from the main actor; queued/late
    /// `feed` work and delivery closures both early-out once this is set.
    func stop() {
        stopped = true
    }
}

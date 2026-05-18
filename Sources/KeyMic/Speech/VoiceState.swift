import Foundation

/// Identifies which physical surface produced a voice toggle.
/// Reserved for telemetry; not yet read by any consumer.
enum VoiceInputToggledFrom: Equatable {
    case button
    case key(state: KeyState)
}

enum KeyState: Equatable {
    case down
    case up
}

/// Lifecycle handle for a single voice capture. Holding the session keeps
/// the underlying audio engine + recognition task alive. Calling `cancel()`
/// (or releasing the last strong reference) tears them down. Owned by
/// `AppDelegate`; produced by `SpeechEngine.startSession`.
final class VoiceSession {
    let id: UUID
    let startedAt: Date
    private var closeHook: (() -> Void)?

    init(id: UUID = UUID(), startedAt: Date = Date(), close: @escaping () -> Void) {
        self.id = id
        self.startedAt = startedAt
        self.closeHook = close
    }

    /// Idempotent. After the first call further invocations are no-ops.
    func cancel() {
        let hook = closeHook
        closeHook = nil
        hook?()
    }

    deinit {
        cancel()
    }
}

/// Voice pipeline lifecycle.
///
/// Allowed transitions (see plan §"Transition table"):
///   .idle         → .listening
///   .listening    → .transcribing   (trigger up / 6-min timeout)
///   .listening    → .idle           (cancel)
///   .transcribing → .idle           (final result, grace timeout, cancel)
///   .transcribing → .listening      (trigger down again — aborts session)
///   any           → .idle           (extraneous key / error)
enum VoiceState {
    case idle
    case listening(session: VoiceSession)
    case transcribing(session: VoiceSession)

    var session: VoiceSession? {
        switch self {
        case .idle: return nil
        case .listening(let s), .transcribing(let s): return s
        }
    }

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

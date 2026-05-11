import CoreGraphics
import Foundation

/// Transient input state owned by `KeyMonitor`. Excludes repeat timers, which
/// hold reference-type `DispatchSourceTimer` and cannot live in a value type.
/// `resetTransient()` is the only mutation path that clears all fields together.
struct InputState {
    var triggerActive: Bool = false
    var heldModifiers: Set<CGKeyCode> = []
    var remappedKeysDown: Set<CGKeyCode> = []

    /// Idempotent. Returns the previous state for logging.
    @discardableResult
    mutating func resetTransient() -> InputState {
        let prior = self
        triggerActive = false
        heldModifiers.removeAll()
        remappedKeysDown.removeAll()
        return prior
    }
}

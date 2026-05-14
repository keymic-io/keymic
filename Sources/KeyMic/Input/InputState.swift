import CoreGraphics
import Foundation

/// Transient input state owned by `KeyMonitor`. Excludes repeat timers, which
/// hold reference-type `DispatchSourceTimer` and cannot live in a value type.
/// `resetTransient()` is the only mutation path that clears all fields together.
struct InputState {
    var triggerActive: Bool = false
    var heldModifiers: Set<CGKeyCode> = []
    var remappedKeysDown: Set<CGKeyCode> = []
    /// Non-nil while a persona hotkey is held down as a push-to-talk trigger.
    /// Stores the primary keyCode (e.g. 'z' for alt+z) so its matching keyUp
    /// can release the synthetic voice trigger.
    var personaHotkeyKeyDown: CGKeyCode? = nil

    /// Idempotent. Returns the previous state for logging.
    @discardableResult
    mutating func resetTransient() -> InputState {
        let prior = self
        triggerActive = false
        heldModifiers.removeAll()
        remappedKeysDown.removeAll()
        personaHotkeyKeyDown = nil
        return prior
    }
}

import Foundation

/// Why `KeyMonitor.resetAllInputState` was invoked.
/// Used for structured logging and for future per-reason behavior (e.g.,
/// suspending hotkey dispatch only on `.secureInputEnter`).
enum InputResetReason: String, CustomStringConvertible {
    case tapDisabledByTimeout
    case tapDisabledByUserInput
    case tapRebuild
    case tapHealthCheckReenable
    case secureInputEnter
    case settingsReload
    case hotkeyRecorderStart
    case stop

    var description: String { rawValue }
}

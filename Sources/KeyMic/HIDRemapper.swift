import CoreGraphics
import Foundation
import os

/// Caps Lock cannot be intercepted at session-event-tap level — by the time the event reaches us
/// the HID system has already toggled the lock state. The only reliable way to remap Caps Lock
/// (without a kernel extension) is to install an HID-level UserKeyMapping via `hidutil`, the
/// same mechanism used by Karabiner-Elements and Hyperkey.
///
/// We use this exclusively for mappings whose source is Caps Lock; all other mappings continue
/// to be handled by `KeyMonitor`'s session event tap. Mappings installed here persist for the
/// current login session — `reset()` is called on app quit.
enum HIDRemapper {
    private static let log = Logger(subsystem: "io.keymic.app", category: "HIDRemapper")
    private static let hidutilPath = "/usr/bin/hidutil"
    private static let capsLockKeyCode: CGKeyCode = 0x39

    /// Install the HID-level mapping for any enabled `Caps Lock → X` entries.
    /// All other mappings are ignored (handled by the session event tap).
    static func apply(_ mappings: [KeyMapping], enabled: Bool) {
        let pairs: [(from: UInt64, to: UInt64)] = enabled
            ? mappings.compactMap(usagePair).filter { $0.from == hidUsage(for: capsLockKeyCode) }
            : []
        setUserKeyMapping(pairs, synchronously: false)
    }

    /// Remove any mapping previously installed via `apply`. Call on app quit.
    /// Runs synchronously because `applicationWillTerminate` doesn't pump the run
    /// loop after returning — an async dispatch would be killed before `hidutil` runs
    /// and the mapping would survive into the next login session.
    static func reset() {
        setUserKeyMapping([], synchronously: true)
    }

    /// Serial queue so concurrent updates don't race; off-main so `waitUntilExit`
    /// doesn't stall the main thread (event-tap callback runs on main and a >1s
    /// stall trips macOS's `tapDisabledByTimeout`, freezing kbd/mouse globally).
    private static let queue = DispatchQueue(label: "io.keymic.app.hidutil", qos: .userInitiated)

    private static func setUserKeyMapping(_ pairs: [(from: UInt64, to: UInt64)], synchronously: Bool) {
        let entries = pairs.map { pair in
            #"{"HIDKeyboardModifierMappingSrc":\#(pair.from),"HIDKeyboardModifierMappingDst":\#(pair.to)}"#
        }
        let json = #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#
        let work = {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: hidutilPath)
            task.arguments = ["property", "--set", json]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    log.error("hidutil returned \(task.terminationStatus, privacy: .public) for \(json, privacy: .public)")
                }
            } catch {
                log.error("hidutil launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if synchronously {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private static func usagePair(_ m: KeyMapping) -> (from: UInt64, to: UInt64)? {
        guard m.enabled,
              let f = m.fromKeyCode, let t = m.toKeyCode,
              let fu = hidUsage(for: f), let tu = hidUsage(for: t)
        else { return nil }
        return (fu, tu)
    }

    /// Virtual keycode → HID usage on the Keyboard usage page (0x07).
    /// Covers the keys exposed in `KeyMapping`'s recorder UI.
    private static func hidUsage(for keyCode: CGKeyCode) -> UInt64? {
        switch keyCode {
        // Modifiers
        case 0x36: return 0x7000000E7  // Right Cmd
        case 0x37: return 0x7000000E3  // Left Cmd
        case 0x38: return 0x7000000E1  // Left Shift
        case 0x3C: return 0x7000000E5  // Right Shift
        case 0x3A: return 0x7000000E2  // Left Option
        case 0x3D: return 0x7000000E6  // Right Option
        case 0x3B: return 0x7000000E0  // Left Control
        case 0x3E: return 0x7000000E4  // Right Control
        case 0x39: return 0x700000039  // Caps Lock
        // Common non-modifier targets
        case 0x35: return 0x700000029  // Escape
        case 0x33: return 0x70000002A  // Delete (Backspace)
        case 0x75: return 0x70000004C  // Forward Delete
        case 0x24: return 0x700000028  // Return
        case 0x30: return 0x70000002B  // Tab
        case 0x31: return 0x70000002C  // Space
        case 0x73: return 0x70000004A  // Home
        case 0x77: return 0x70000004D  // End
        case 0x74: return 0x70000004B  // Page Up
        case 0x79: return 0x70000004E  // Page Down
        case 0x7B: return 0x700000050  // ←
        case 0x7C: return 0x70000004F  // →
        case 0x7D: return 0x700000051  // ↓
        case 0x7E: return 0x700000052  // ↑
        default: return nil
        }
    }
}

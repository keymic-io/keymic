import AppKit
import Foundation
import os.log

private let itermLogger = Logger(subsystem: "io.keymic.app", category: "ITermBridge")

/// AppleScript bridge to iTerm 2.
///
/// AppleScript chosen over the iTerm Python API to keep the integration zero-setup —
/// the Python API requires installing a Python runtime and enabling iTerm's API setting.
enum ITermBridge {
    enum Error: Swift.Error, Equatable {
        case permissionDenied            // NSAppleScriptErrorNumber == -1743
        case appleScriptFailed(String)
        case iTermNotRunning             // returned "no-window" sentinel from script
        case paneOutOfRange              // returned "out-of-range" sentinel
    }

    @MainActor
    static func write(text: String, paneIndex: Int) async throws {
        let escaped = escapeForAppleScript(text)
        // Pane index +1 because AppleScript is 1-indexed.
        let scriptSource = """
        tell application "iTerm"
            if (count of windows) = 0 then
                return "no-window"
            end if
            tell current window
                set sessionList to sessions
                if (count of sessionList) < \(paneIndex + 1) then
                    return "out-of-range"
                end if
                tell item \(paneIndex + 1) of sessionList
                    write text "\(escaped)"
                end tell
            end tell
            return "ok"
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            throw Error.appleScriptFailed("NSAppleScript init returned nil")
        }
        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict = errorDict as? [String: Any] {
            if let code = errorDict["NSAppleScriptErrorNumber"] as? Int, code == -1743 {
                itermLogger.error("iTerm AppleScript denied (errAEEventNotPermitted)")
                throw Error.permissionDenied
            }
            let message = (errorDict["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
            itermLogger.error("iTerm AppleScript failed: \(message, privacy: .public)")
            throw Error.appleScriptFailed(message)
        }
        let sentinel = descriptor.stringValue ?? "ok"
        switch sentinel {
        case "no-window":     throw Error.iTermNotRunning
        case "out-of-range":  throw Error.paneOutOfRange
        default: break
        }
        itermLogger.debug("iTerm write pane=\(paneIndex, privacy: .public) length=\(text.count, privacy: .public)")
    }

    /// Escapes for embedding in an AppleScript string literal.
    /// - `\` → `\\`
    /// - `"` → `\"`
    /// - newline → `" & return & "`
    static func escapeForAppleScript(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\" & return & \"")
            default:   out.append(ch)
            }
        }
        return out
    }
}

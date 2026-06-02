import AppKit
import Foundation

/// Bundle-presence probe for iTerm 2. Used by `OutputRouter.writeToITerm` to short-circuit
/// with a clean error message when iTerm isn't installed.
///
/// We deliberately do NOT probe the Automation TCC state here — there is no public API
/// for that, and the first AppleScript dispatch triggers the prompt natively.
enum ITermAvailability {
    static let bundleID: String = "com.googlecode.iterm2"

    static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

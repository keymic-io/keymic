import AppKit
import CoreGraphics

/// Test-friendly view of the SCWindow fields used by the focused-window heuristic.
/// Production code conforms `SCWindow` to this protocol via an extension below.
protocol WindowCandidate {
    var owningPID: pid_t? { get }
    var isOnScreen: Bool { get }
    var windowLayer: Int { get }
    var frameArea: CGFloat { get }
}

/// Errors emitted by `WindowOCRProvider.recognize()`.
/// `.noFocusedWindow` is **not** thrown by `recognize()` itself (which returns nil for no-window);
/// it exists for explicit callers that want to distinguish "no window" from "permission denied".
enum WindowOCRError: Error {
    /// NSWorkspace returned nil / window not in SCShareableContent.
    case noFocusedWindow
    /// TCC denial — surfaces as SCShareableContent failure.
    case screenRecordingDenied
    /// SCScreenshotManager threw.
    case captureFailed(Error)
    /// VNImageRequestHandler / VNRecognizeTextRequest threw.
    case visionFailed(Error)
}

/// Captures the currently focused window and runs Vision OCR on the pixels.
/// Actor-isolated so concurrent voice triggers serialize (one OCR at a time).
actor WindowOCRProvider {
    static let shared = WindowOCRProvider()

    /// Returns true if Screen Recording TCC is currently granted.
    /// Static so the synchronous permission gate in `PersonaContextBuilder` doesn't need actor hopping.
    nonisolated static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Filters the user's preferred BCP-47 language list down to Vision's supported set.
    /// Match rule: an entry like `zh-Hans-CN` matches a supported `zh-Hans` (longest-prefix match
    /// over `-`-separated subtags). Preferred order is preserved; unsupported entries dropped.
    /// Returns `[]` when nothing matches — caller should pass `[]` straight to
    /// `VNRecognizeTextRequest.recognitionLanguages` so Vision falls back to its default.
    nonisolated static func resolvedRecognitionLanguages(
        preferred: [String],
        supported: [String]
    ) -> [String] {
        var result: [String] = []
        for pref in preferred {
            if supported.contains(pref) {
                if !result.contains(pref) { result.append(pref) }
                continue
            }
            var subtags = pref.split(separator: "-").map(String.init)
            while subtags.count > 1 {
                subtags.removeLast()
                let candidate = subtags.joined(separator: "-")
                if supported.contains(candidate) {
                    if !result.contains(candidate) { result.append(candidate) }
                    break
                }
            }
        }
        return result
    }

    /// Picks the focused window from a list of candidates, using the heuristic:
    /// - Owning PID matches the frontmost application.
    /// - `isOnScreen == true`.
    /// - `windowLayer == 0` (filters inspectors / floating panels at higher layers).
    /// - Among survivors, the largest `frameArea`.
    /// Returns nil if no candidate qualifies (e.g. Finder desktop, all windows minimized).
    nonisolated static func pickFocusedWindow<W: WindowCandidate>(
        in candidates: [W],
        frontPID: pid_t
    ) -> W? {
        let filtered = candidates.filter {
            $0.owningPID == frontPID && $0.isOnScreen && $0.windowLayer == 0
        }
        return filtered.max { $0.frameArea < $1.frameArea }
    }
}

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

@available(macOS 14.0, *)
extension SCWindow: WindowCandidate {
    var owningPID: pid_t? { owningApplication?.processID }
    var frameArea: CGFloat { frame.width * frame.height }
}
#endif

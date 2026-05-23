import AppKit
import CoreGraphics

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
}

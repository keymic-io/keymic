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
}

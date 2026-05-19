import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "WindowOCRSource")

/// Placeholder. Real focused-window OCR (ScreenCaptureKit + VNRecognizeTextRequest)
/// lands with LOR-20 in a separate plan. Returns nil so personas with
/// `contextMode = .windowOCR` degrade to LLM-only on the rest of the fragments.
final class WindowOCRSource: ContextSource {
    private var loggedDisabled = false

    var providedKind: TextSource { .ocrWindow }

    func read() async throws -> TextFragment? {
        if !loggedDisabled {
            loggedDisabled = true
            logger.info("OCR source not implemented yet — returning nil")
        }
        return nil
    }
}

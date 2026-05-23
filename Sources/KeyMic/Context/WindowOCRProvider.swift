import AppKit
import CoreGraphics
import Vision

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

    /// Captures the focused window's pixels and returns recognized text.
    /// Returns nil when there's no focused window (no error — "no context" is a normal outcome).
    /// Throws on TCC denial or Vision errors so the caller can decide policy.
    func recognize() async throws -> String? {
        #if canImport(ScreenCaptureKit)
        guard #available(macOS 14.0, *) else { return nil }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw WindowOCRError.screenRecordingDenied
        }

        guard let frontApp = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else {
            return nil
        }
        guard let scWindow = Self.pickFocusedWindow(in: content.windows, frontPID: frontApp.processIdentifier) else {
            return nil
        }

        let cgImage: CGImage
        do {
            cgImage = try await captureImage(of: scWindow)
        } catch {
            throw WindowOCRError.captureFailed(error)
        }

        do {
            return try Self.recognizeText(in: cgImage)
        } catch {
            throw WindowOCRError.visionFailed(error)
        }
        #else
        return nil
        #endif
    }

    /// Runs Vision on a captured window image and returns top-to-bottom concatenated text.
    /// Returns nil if Vision found no candidate strings (e.g. screenshot of a blank canvas).
    @available(macOS 14.0, *)
    nonisolated static func recognizeText(
        in cgImage: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) throws -> String? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: recognitionLevel,
            revision: VNRecognizeTextRequest.currentRevision
        )) ?? []
        request.recognitionLanguages = resolvedRecognitionLanguages(
            preferred: Locale.preferredLanguages,
            supported: supported
        )
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    #if canImport(ScreenCaptureKit)
    @available(macOS 14.0, *)
    private func captureImage(of scWindow: SCWindow) async throws -> CGImage {
        let scale = await MainActor.run { () -> CGFloat in
            NSScreen.screens.first { screen in
                scWindow.frame.intersects(screen.frame)
            }?.backingScaleFactor ?? 2.0
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.scalesToFit = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    #endif
}

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

@available(macOS 14.0, *)
extension SCWindow: WindowCandidate {
    var owningPID: pid_t? { owningApplication?.processID }
    var frameArea: CGFloat { frame.width * frame.height }
}
#endif

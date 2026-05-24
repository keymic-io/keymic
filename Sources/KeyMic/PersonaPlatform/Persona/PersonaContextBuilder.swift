import Foundation

/// Assembles a `PersonaContext` from the sources a persona declares.
/// Centralises what used to be inline in `AppDelegate.finishTranscription`.
///
/// Cheap sources (selection, clipboard) are gathered synchronously; the slow
/// `.windowOCR` source is awaited last and posts a "Reading screen…" status
/// via `onStatusUpdate`. Provider errors are swallowed — a missing source
/// degrades the prompt but never blocks the LLM call.
@MainActor
enum PersonaContextBuilder {
    /// Side-effect adapters. Production callsites use `.live(...)`; tests inject stubs.
    /// All closures are `@MainActor` because the live wiring touches AppKit / SwiftData
    /// APIs that require main-actor isolation. Builder itself is `@MainActor` too.
    struct Providers {
        var selection: @MainActor () -> String?
        var clipboardTop: @MainActor () -> String?
        var clipboardHistory: @MainActor (_ limit: Int) -> [String]?
        var windowOCR: @MainActor () async throws -> String?
    }

    /// Test entry point — bypasses Persona / ClipboardStore wiring.
    /// Same logic as `build(for:)` but exposes the providers directly.
    static func testBuild(
        sources: Set<ContextSource>,
        providers: Providers,
        onStatusUpdate: @escaping (String) -> Void
    ) async -> PersonaContext {
        await gather(sources: sources, providers: providers, onStatusUpdate: onStatusUpdate)
    }

    static func gather(
        sources: Set<ContextSource>,
        providers: Providers,
        onStatusUpdate: (String) -> Void
    ) async -> PersonaContext {
        var selection: String? = nil
        var clipboardTop: String? = nil
        var clipboardHistory: [String]? = nil
        var windowOCR: String? = nil

        // Cheap synchronous sources first.
        if sources.contains(.selection) {
            selection = providers.selection()
        }
        if sources.contains(.clipboardTop) {
            clipboardTop = providers.clipboardTop()
        }
        if sources.contains(.clipboardHistory) {
            clipboardHistory = providers.clipboardHistory(10)
        }

        // Slow async OCR last, with status update.
        if sources.contains(.windowOCR) {
            onStatusUpdate(String(localized: "Reading screen…"))
            do {
                windowOCR = try await providers.windowOCR()
            } catch {
                // Permission denial / capture failure: skip silently. The caller
                // (AppDelegate) is responsible for any one-time TCC permission toast.
                windowOCR = nil
            }
        }

        return PersonaContext(
            selection: selection,
            clipboardTop: clipboardTop,
            clipboardHistory: clipboardHistory,
            windowOCR: windowOCR
        )
    }
}

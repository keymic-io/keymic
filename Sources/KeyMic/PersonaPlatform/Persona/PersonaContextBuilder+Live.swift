import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension PersonaContextBuilder.Providers {
    /// Real-world adapter wiring the existing app singletons.
    /// `clipboardStore` is **required** because `ClipboardStore` is not a singleton —
    /// `AppDelegate` owns the instance via `ClipboardController`.
    static func live(clipboardStore: ClipboardStore) -> Self {
        #if canImport(AppKit)
        return Self(
            selection: { SelectionTextProvider.currentSelection() },
            clipboardTop: { NSPasteboard.general.string(forType: .string) },
            clipboardHistory: { limit in clipboardStore.recentTexts(limit: limit) },
            windowOCR: { try await WindowOCRProvider.shared.recognize() }
        )
        #else
        return Self(
            selection: { nil },
            clipboardTop: { nil },
            clipboardHistory: { _ in nil },
            windowOCR: { nil }
        )
        #endif
    }
}

extension PersonaContextBuilder {
    /// Convenience entry point — wires the real providers via `.live(clipboardStore:)`.
    /// `clipboardStore` is required (no default) because there is no `ClipboardStore.shared`.
    static func build(
        for persona: Persona,
        clipboardStore: ClipboardStore,
        onStatusUpdate: @escaping (String) -> Void = { _ in }
    ) async -> PersonaContext {
        let providers = Providers.live(clipboardStore: clipboardStore)
        return await gather(sources: persona.contextSources,
                            providers: providers,
                            onStatusUpdate: onStatusUpdate)
    }
}

import AppKit
import Foundation
import os.log

private let transformerLogger = Logger(subsystem: "io.keymic.app", category: "ClipboardTransformer")

/// Coordinates a single Clipboard Transformer LLM call against a batch of items.
/// One instance lives on AppDelegate; called by `ClipboardController.transformSelected()`.
@MainActor
final class ClipboardTransformController {
    static let personaID = "builtin-clipboard-transformer"

    private let store: ClipboardStore
    private let llm: LLMRefiner
    private let outputRouter: () -> OutputRouter
    private weak var overlayPanel: OverlayPanel?

    private var inFlight: Bool = false

    init(store: ClipboardStore,
         llm: LLMRefiner = .shared,
         outputRouter: @autoclosure @escaping () -> OutputRouter = OutputRouter.shared,
         overlayPanel: OverlayPanel? = nil) {
        self.store = store
        self.llm = llm
        self.outputRouter = outputRouter
        self.overlayPanel = overlayPanel
    }

    func attach(overlayPanel: OverlayPanel) {
        self.overlayPanel = overlayPanel
    }

    /// Public entry point. Called by ClipboardController.transformSelected().
    /// Items should be in user-selection / visual order (top-of-history first).
    func transform(items: [ClipboardItem]) {
        guard !inFlight else {
            transformerLogger.debug("transform: ignored, already in flight")
            return
        }
        guard !items.isEmpty else {
            overlayPanel?.showTransientToast(
                String(localized: "Select at least one clipboard item"),
                durationSeconds: 2.0
            )
            return
        }

        let texts = items.map(\.text)
        if let sizeError = ClipboardTransformPrompt.validateSize(items: texts) {
            transformerLogger.debug("transform: size validation failed")
            overlayPanel?.showTransientToast(sizeError, durationSeconds: 3.0)
            return
        }

        let userMessage = ClipboardTransformPrompt.composeBatchUserMessage(items: texts)
        let (systemPrompt, temperature) = resolvePersonaSettings()

        inFlight = true
        overlayPanel?.showTransientToast(
            String(localized: "Transforming \(items.count) item(s)…"),
            durationSeconds: 1.5
        )
        transformerLogger.debug("transform: count=\(items.count, privacy: .public) chars=\(userMessage.utf16.count, privacy: .public)")

        Task { @MainActor in
            defer { inFlight = false }
            do {
                let result: String = try await withCheckedThrowingContinuation { cont in
                    llm.refine(userMessage, systemPrompt: systemPrompt, temperature: temperature) { res in
                        cont.resume(with: res)
                    }
                }
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    overlayPanel?.showTransientToast(
                        String(localized: "Transform produced no output"),
                        durationSeconds: 3.0
                    )
                    return
                }

                // 1. Insert at top of history.
                store.add(
                    text: trimmed,
                    sourceBundleID: Bundle.main.bundleIdentifier,
                    sourceAppName: "Clipboard Transformer"
                )

                // 2. Sync to system pasteboard via OutputRouter.
                let output = PersonaOutput(
                    text: trimmed,
                    strategy: .clipboard,
                    originatingApp: nil,
                    context: nil
                )
                _ = await outputRouter().route(output)

                overlayPanel?.showTransientToast(
                    String(localized: "Transformed \(items.count) item(s)"),
                    durationSeconds: 1.8
                )
                transformerLogger.debug("transform: success out_chars=\(trimmed.utf16.count, privacy: .public)")
            } catch {
                overlayPanel?.showTransientToast(
                    String(localized: "Transform failed: \(error.localizedDescription)"),
                    durationSeconds: 3.0
                )
                transformerLogger.error("transform: LLM failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func resolvePersonaSettings() -> (systemPrompt: String, temperature: Double) {
        if let persona = PersonaStore.shared.persona(id: Self.personaID) {
            return (persona.stylePrompt, persona.temperature)
        }
        return (ClipboardTransformPrompt.systemPromptFallback, 0.4)
    }
}

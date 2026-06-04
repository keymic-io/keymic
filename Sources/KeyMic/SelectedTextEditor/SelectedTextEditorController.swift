import AppKit
import ApplicationServices
import Foundation
import os.log

private let editorLogger = Logger(subsystem: "io.keymic.app", category: "SelectedTextEditor")

/// Public entry point for the Selected Text Editor panel.
/// One instance lives on AppDelegate; `open()` is invoked by HotkeyActionRunner when the user fires the editor hotkey.
@MainActor
final class SelectedTextEditorController {
    static let generalEditorPersonaID = "builtin-general-editor"

    let state = SelectedTextEditorState()

    private var speechEngine: any SpeechEngineProtocol
    private let llm: LLMRefiner
    private let outputRouter: () -> OutputRouter
    private weak var overlayPanel: OverlayPanel?

    private lazy var panel: SelectedTextEditorPanel = {
        let p = SelectedTextEditorPanel(controller: self)
        return p
    }()

    /// Active voice session for the panel's hold-to-talk button.
    private var voiceSession: VoiceSession?

    /// Saved speech callbacks captured the first time the controller takes over,
    /// so we can always restore the originals (avoids accidental stacking).
    private var savedOnPartial: ((String) -> Void)?
    private var savedOnFinal: ((String) -> Void)?
    private var savedOnError: ((String) -> Void)?
    private var savedOnAudioLevel: ((Float) -> Void)?
    private var didSaveCallbacks: Bool = false

    init(speechEngine: any SpeechEngineProtocol,
         llm: LLMRefiner = .shared,
         outputRouter: @autoclosure @escaping () -> OutputRouter = OutputRouter.shared,
         overlayPanel: OverlayPanel? = nil) {
        self.speechEngine = speechEngine
        self.llm = llm
        self.outputRouter = outputRouter
        self.overlayPanel = overlayPanel
    }

    func attach(overlayPanel: OverlayPanel) {
        self.overlayPanel = overlayPanel
    }

    /// Swap the speech engine (e.g. after the SenseVoice backend is toggled in Settings).
    /// Stops any in-flight hold-to-talk session on the old engine before swapping; the saved
    /// callbacks are cleared so the new engine doesn't inherit stale state.
    func replaceEngine(_ engine: any SpeechEngineProtocol) {
        if state.isRecording || voiceSession != nil {
            speechEngine.endAudio()
            voiceSession = nil
            state.isRecording = false
        }
        restoreSpeechCallbacks()
        speechEngine = engine
    }

    // MARK: - Open / close

    /// Reads the current selection, fills state, and brings the panel up.
    /// No-op (with toast) when there's no selection or Accessibility is denied.
    func open() {
        guard AXIsProcessTrusted() else {
            editorLogger.debug("open: AX permission missing")
            overlayPanel?.showTransientToast(
                String(localized: "Accessibility permission needed"),
                durationSeconds: 3.0
            )
            return
        }

        guard let raw = SelectionTextProvider.currentSelection(), !raw.isEmpty else {
            editorLogger.debug("open: no selection")
            overlayPanel?.showTransientToast(
                String(localized: "No selection — select text first"),
                durationSeconds: 2.0
            )
            return
        }

        let originating = NSWorkspace.shared.frontmostApplication
        state.reset()
        state.selectionFullText = raw
        state.selectionPreview = makePreview(from: raw)
        state.originatingApp = originating

        editorLogger.debug("open: bundle=\(originating?.bundleIdentifier ?? "nil", privacy: .public) chars=\(raw.count, privacy: .public)")
        panel.presentNearSelection()
    }

    func close() {
        stopVoice()
        panel.dismiss()
        state.reset()
    }

    // MARK: - Voice

    /// Begins a hold-to-talk session driving `state.instructionText`.
    /// Saves and replaces the SpeechEngine's existing callbacks; restored in `stopVoice()`.
    func startVoice() {
        guard !state.isRecording else { return }
        saveSpeechCallbacksIfNeeded()
        speechEngine.onPartialResult = { [weak self] text in
            DispatchQueue.main.async { self?.state.instructionText = text }
        }
        speechEngine.onFinalResult = { [weak self] text in
            DispatchQueue.main.async {
                self?.state.instructionText = text
                self?.state.isRecording = false
            }
        }
        speechEngine.onError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.state.isRecording = false
                self?.state.errorMessage = msg
            }
        }
        speechEngine.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async { self?.state.audioLevel = level }
        }
        do {
            voiceSession = try speechEngine.startSession()
            state.isRecording = true
            state.errorMessage = nil
            editorLogger.debug("voice session started")
        } catch {
            state.errorMessage = error.localizedDescription
            restoreSpeechCallbacks()
        }
    }

    /// Ends audio capture; transcript is delivered to `state.instructionText` via the final callback.
    func stopVoice() {
        guard state.isRecording || voiceSession != nil else {
            restoreSpeechCallbacks()
            return
        }
        speechEngine.endAudio()
        voiceSession = nil
        state.isRecording = false
        // Restore callbacks after a brief delay to allow the final result to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.restoreSpeechCallbacks()
        }
    }

    private func saveSpeechCallbacksIfNeeded() {
        guard !didSaveCallbacks else { return }
        savedOnPartial = speechEngine.onPartialResult
        savedOnFinal = speechEngine.onFinalResult
        savedOnError = speechEngine.onError
        savedOnAudioLevel = speechEngine.onAudioLevel
        didSaveCallbacks = true
    }

    private func restoreSpeechCallbacks() {
        guard didSaveCallbacks else { return }
        speechEngine.onPartialResult = savedOnPartial
        speechEngine.onFinalResult = savedOnFinal
        speechEngine.onError = savedOnError
        speechEngine.onAudioLevel = savedOnAudioLevel
        savedOnPartial = nil
        savedOnFinal = nil
        savedOnError = nil
        savedOnAudioLevel = nil
        didSaveCallbacks = false
    }

    // MARK: - Apply

    /// Composes the LLM request, awaits the refined output, and routes via OutputRouter.
    /// On `.injected` → closes panel. On fallback/error → keeps panel open showing the result.
    func apply() async {
        guard !state.isRunning else { return }
        state.isRunning = true
        state.errorMessage = nil
        state.statusMessage = nil
        defer { state.isRunning = false }

        let instruction = EditorPrompt.buildInstruction(
            action: state.selectedAction,
            typed: state.instructionText
        )

        // Free-form requires an actual instruction; gate at the controller too in case UI bypassed disabled-state.
        if state.selectedAction == .freeForm && instruction.isEmpty {
            state.errorMessage = String(localized: "Type or speak an instruction first")
            return
        }

        let userMessage = EditorPrompt.composeUserMessage(
            selection: state.selectionFullText,
            instruction: instruction
        )
        let systemPrompt = resolveSystemPrompt()

        editorLogger.debug("apply: action=\(self.state.selectedAction.rawValue, privacy: .public) instr_chars=\(instruction.count, privacy: .public) sel_chars=\(self.state.selectionFullText.count, privacy: .public)")

        do {
            let refined: String = try await withCheckedThrowingContinuation { cont in
                llm.refine(userMessage, systemPrompt: systemPrompt, temperature: 0.4) { result in
                    cont.resume(with: result)
                }
            }
            state.result = refined

            let output = PersonaOutput(
                text: refined,
                strategy: .replaceSelection,
                originatingApp: state.originatingApp,
                context: PersonaContext(selection: state.selectionFullText, clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)
            )
            let routeResult = await outputRouter().route(output)
            state.routeResult = routeResult
            editorLogger.debug("apply: route=\(String(describing: routeResult), privacy: .public)")

            switch routeResult {
            case .injected:
                close()
            case .fellBackToClipboard(let reason):
                state.statusMessage = Self.label(for: reason)
            case .userCancelled:
                state.statusMessage = nil
            case .failed(let message):
                state.errorMessage = message
            }
        } catch {
            state.errorMessage = error.localizedDescription
            editorLogger.error("apply: LLM failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveSystemPrompt() -> String {
        if let persona = PersonaStore.shared.persona(id: Self.generalEditorPersonaID) {
            return persona.stylePrompt
        }
        return EditorPrompt.systemPrompt
    }

    private static func label(for reason: FallbackReason) -> String {
        switch reason {
        case .selectionNotEditable:
            return String(localized: "Copied — couldn't edit in place")
        case .noFocusedElement:
            return String(localized: "Copied — no focused field")
        case .axPermissionMissing:
            return String(localized: "Copied — Accessibility permission needed")
        case .strategyNotImplemented:
            return String(localized: "Copied — strategy coming soon")
        }
    }

    private func makePreview(from text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxChars = 80
        if oneLine.count <= maxChars {
            return "\(oneLine)  (\(text.count))"
        }
        let trimmed = String(oneLine.prefix(maxChars))
        return "\(trimmed)…  (\(text.count))"
    }
}

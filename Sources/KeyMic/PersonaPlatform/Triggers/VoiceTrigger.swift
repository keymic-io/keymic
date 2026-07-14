import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "VoiceTrigger")

@MainActor
final class VoiceTrigger: SpeechClient {
    private let engine: PersonaEngine
    private let sessionHost: SpeechSessionHost
    private let overlayPanel: OverlayPanel
    private let personaStore: PersonaStore
    private let clipboardStore: ClipboardStore
    private let textInjector: TextInjector

    private var session: SpeechSession?
    private var isRecording = false
    private var lastPartial = ""
    private var finalResultTimer: Timer?
    private var runTask: Task<Void, Never>?
    private var originatingApp: NSRunningApplication?

    private let pickerState = VoicePickerState()
    private lazy var pickerPanel = VoicePickerPanel(state: pickerState)
    private var consolePanel: ContextConsolePanel?
    /// Source of the current session; decides picker/console vs direct run.
    private var currentSource: VoiceTriggerSource = .defaultTrigger

    var isActive: Bool {
        isRecording || session != nil || finalResultTimer != nil || runTask != nil || consolePanel != nil
    }

    /// True only while a recording/refine is live — NOT while the post-release
    /// console is open. KeyMonitor uses this to decide extraneous-key cancel and
    /// Tab-cycle; the console must be keyboard-usable, so it must read false here.
    var isVoiceSessionLive: Bool {
        isRecording || session != nil || finalResultTimer != nil || runTask != nil
    }

    /// True while the post-release context console is open. KeyMonitor reads this
    /// (synchronously) to pass the trigger key THROUGH — no new session, no
    /// interrupt — so the console stays open and Option-modified typing works in it.
    var isConsoleOpen: Bool { consolePanel != nil }

    /// True only during a DEFAULT-trigger recording (picker up). KeyMonitor gates
    /// Tab-cycle interception on this, NOT on whether a persona hotkey is currently
    /// held: a persona-hotkey session whose key was already released must keep
    /// today's cancel-on-Tab behavior.
    var isDefaultTriggerVoiceActive: Bool {
        isRecording && currentSource == .defaultTrigger
    }

    init(engine: PersonaEngine,
         sessionHost: SpeechSessionHost,
         overlayPanel: OverlayPanel,
         personaStore: PersonaStore,
         clipboardStore: ClipboardStore,
         textInjector: TextInjector) {
        self.engine = engine
        self.sessionHost = sessionHost
        self.overlayPanel = overlayPanel
        self.personaStore = personaStore
        self.clipboardStore = clipboardStore
        self.textInjector = textInjector
    }

    func onTriggerDown(source: VoiceTriggerSource) {
        guard !isActive else { return }
        currentSource = source
        do {
            let session = try sessionHost.acquire(client: self)
            self.session = session
            originatingApp = NSWorkspace.shared.frontmostApplication
            lastPartial = ""
            isRecording = true
            overlayPanel.show(text: "Listening...")
            switch source {
            case .defaultTrigger:
                showPicker()
            case .personaHotkey(let id):
                // Show the picker as visual feedback: the triggered persona is
                // highlighted and its context (selection + clipboard) previewed.
                // finish() still runs this persona directly — the picker is not
                // interactive here (Tab-cycle stays gated off for persona hotkeys).
                showPicker(highlightPersonaID: id)
            }
            NSSound(named: .init("Tink"))?.play()
            try session.start()
        } catch SpeechSessionError.busy {
            logger.debug("Speech session busy; ignoring trigger down")
        } catch let error as VoiceError {
            failStart(error.displayMessage)
        } catch {
            failStart(error.localizedDescription)
        }
    }

    private func showPicker(highlightPersonaID: String? = nil) {
        // Build entries (default input + MRU personas) and capture a cheap,
        // side-effect-free context snapshot: AX selection + clipboard top only.
        // NEVER a Cmd+C round-trip here — the trigger modifier is held.
        pickerState.entries = VoicePickerModel.buildEntries(
            personas: personaStore.personas,
            history: PersonaMRU.shared.historyIDs()
        )
        // Default trigger starts on "Default input"; a persona hotkey pre-highlights
        // its own persona so its context windows are shown immediately.
        pickerState.highlightedIndex = highlightPersonaID.flatMap { id in
            pickerState.entries.firstIndex {
                if case .persona(let p) = $0 { return p.id == id }
                return false
            }
        } ?? 0
        let axSel = SelectionTextProvider.axOnlySelection()
        pickerState.selectionPreview = axSel
        pickerState.axSelectionUnavailable = (axSel == nil)
        pickerState.fieldTextPreview = SelectionTextProvider.axFocusedFieldValue()
        pickerState.clipboardHistory = clipboardStore.recentTexts(limit: 10)

        // Anchor above the capsule. The capsule sits at y = visibleFrame.minY +
        // bottomOffset with height `height`, so its top is that sum, centered on
        // visibleFrame.midX.
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        pickerPanel.present(aboveCapsuleTop: area.minY + CapsuleLayout.bottomOffset + CapsuleLayout.height, centerX: area.midX)
    }

    func onPersonaCycle(forward: Bool) {
        guard isRecording else { return }
        pickerState.highlightedIndex = VoicePickerModel.cycle(
            index: pickerState.highlightedIndex,
            count: pickerState.entries.count,
            forward: forward
        )
    }

    func onTriggerUp() {
        guard isRecording else { return }
        isRecording = false
        session?.stop()
        finalResultTimer?.invalidate()
        finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    func onTriggerInterrupted() {
        guard isActive else { return }
        // Structured cancellation: cancelling runTask propagates into
        // PersonaEngine.run / URLSession (mapped to InvocationError.cancelled).
        runTask?.cancel()
        runTask = nil
        session?.cancel()
        closeConsole()
        cleanupSessionState(dismissOverlay: true)
    }

    func onExtraneousKeyDuringVoice() {
        onTriggerInterrupted()
    }

    func handlePartial(_ text: String) {
        // Drop callbacks that arrive after the session ended (grace timeout /
        // interruption) — a stale partial must not overwrite the overlay.
        guard session != nil else { return }
        lastPartial = text
        overlayPanel.updateText(text)
    }

    func handleFinal(_ text: String) {
        // A final arriving after the session ended (e.g. a slow batch engine
        // delivering past the 2s grace timeout) must be dropped, otherwise it
        // would trigger a second finish() and inject the same utterance twice.
        guard session != nil else { return }
        lastPartial = text
        isRecording = false
        finalResultTimer?.invalidate()
        finalResultTimer = nil
        finish()
    }

    func handleError(_ msg: String) {
        // Drop errors that arrive after the session ended (released for a run or the
        // console, grace timeout, or interruption). A late engine/speech error must
        // NOT show a toast or schedule cleanup that would tear down an open console
        // and discard the user's edits.
        guard session != nil else { return }
        overlayPanel.showMessage(msg)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.cleanupSessionState(dismissOverlay: true)
        }
    }

    func handleAudioLevel(_ level: Float) {
        // Same rationale as handlePartial/handleFinal: ignore levels after release.
        guard session != nil else { return }
        overlayPanel.updateAudioLevel(level)
    }

    private func finish() {
        // One-shot: a second finish() (late final racing the grace timer) would
        // overwrite runTask and run two concurrent LLM runs → double injection.
        guard runTask == nil else { return }
        finalResultTimer?.invalidate()
        finalResultTimer = nil

        let transcript = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        let originatingApp = self.originatingApp
        guard !transcript.isEmpty else {
            cleanupSessionState(dismissOverlay: true)
            return
        }

        // Persona-hotkey session: run its persona directly (unchanged behavior).
        // NO picker, NO console — honors the scope gate.
        if case .personaHotkey(let id) = currentSource {
            pickerPanel.dismiss()
            guard let persona = personaStore.persona(id: id) else {
                cleanupSessionState(dismissOverlay: true)
                injectAfterPop(transcript, originatingApp: originatingApp)
                return
            }
            runPersona(persona, transcript: transcript, originatingApp: originatingApp,
                       contextOverride: nil)
            return
        }

        // Default trigger: decision comes from the picker highlight, NOT activePersona.
        let highlighted = pickerState.highlightedEntry
        pickerPanel.dismiss()

        // Sources the console can curate. A persona with any source outside this set
        // (e.g. .windowOCR, .clipboardHistory) must run directly so auto-gather still
        // supplies those — the console would otherwise silently drop them.
        let consoleManaged: Set<ContextSource> = [.selection, .clipboardTop]

        switch highlighted {
        case .defaultInput:
            // Path 1: raw injection (no persona / no LLM). Not a persona → no MRU.
            cleanupSessionState(dismissOverlay: true)
            injectAfterPop(transcript, originatingApp: originatingApp)
            return

        case .persona(let persona):
            let usesConsole = !persona.contextSources.isEmpty
                && persona.contextSources.isSubset(of: consoleManaged)
            if usesConsole {
                // Path 3: open the context console; no LLM call yet. MRU recorded on Continue.
                openConsole(for: persona, transcript: transcript, originatingApp: originatingApp)
            } else {
                // Path 2: run persona directly (empty sources OR sources needing auto-gather).
                runPersona(persona, transcript: transcript, originatingApp: originatingApp,
                           contextOverride: nil)
            }
        }
    }

    private func runPersona(_ persona: Persona,
                            transcript: String,
                            originatingApp: NSRunningApplication?,
                            contextOverride: ContextOverride?) {
        // Single MRU boundary for ALL persona runs (picker path 2, console path 3
        // Continue, and persona-hotkey). One-shot: does NOT touch activePersona.
        PersonaMRU.shared.record(persona.id)
        if persona.contextSources.contains(.windowOCR) {
            maybeShowOCRPermissionToast()
        }
        let invocation = Invocation(
            persona: persona,
            transcript: transcript,
            originatingApp: originatingApp,
            outputOverride: nil,
            contextOverride: contextOverride
        )

        overlayPanel.showRefining()
        // Release the speech session BEFORE starting the run: this detaches us from
        // the session host so any late final/partial from a slow engine can no longer
        // re-enter handleFinal/handlePartial while the LLM run is in flight.
        session?.release()
        session = nil
        runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.runTask = nil
                    self.cleanupSessionState(dismissOverlay: false)
                }
            }

            do {
                let result = try await self.engine.run(invocation) { [weak self] status in
                    self?.overlayPanel.updateText(status)
                }
                switch result {
                case .bypassed(.emptyInput):
                    await MainActor.run {
                        self.overlayPanel.dismiss()
                    }
                case .routed(_, _, let routeResult):
                    await MainActor.run {
                        self.overlayPanel.dismiss()
                        self.overlayPanel.showRouteResult(routeResult)
                    }
                }
            } catch InvocationError.cancelled {
                await MainActor.run {
                    self.overlayPanel.dismiss()
                }
            } catch {
                // A cancelled run must never fall back to injecting the raw
                // transcript — focus may have moved since. Covers any cancellation
                // shape not already mapped to InvocationError.cancelled upstream.
                guard !Task.isCancelled else {
                    await MainActor.run { self.overlayPanel.dismiss() }
                    return
                }
                logger.error("Persona run failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.overlayPanel.showMessage(String(localized: "Refine failed: \(error.localizedDescription)"))
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self.overlayPanel.dismiss()
                }
                let routeResult = await OutputRouter.shared.route(
                    PersonaOutput(
                        text: transcript,
                        strategy: persona.injectionStrategy,
                        originatingApp: originatingApp,
                        context: nil
                    )
                )
                await MainActor.run {
                    self.overlayPanel.showRouteResult(routeResult)
                }
            }
        }
    }

    private func openConsole(for persona: Persona,
                             transcript: String,
                             originatingApp: NSRunningApplication?) {
        // Release the speech session; dismiss the capsule (the console replaces it).
        session?.release()
        session = nil
        overlayPanel.dismiss()

        // Build candidates: persona's declared sources pre-checked, plus clipboard
        // history (unchecked) to add more. The authoritative gather happens here,
        // AFTER release, so the Cmd+C fallback in currentSelection() is safe.
        var candidates: [ContextCandidate] = []
        if persona.contextSources.contains(.selection),
           let sel = SelectionTextProvider.currentSelection(), !sel.isEmpty {
            candidates.append(ContextCandidate(id: "sel", kind: .selection, text: sel, isChecked: true))
        }
        if persona.contextSources.contains(.clipboardTop),
           let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            candidates.append(ContextCandidate(id: "clip", kind: .clipboardTop, text: clip, isChecked: true))
        }
        for (i, item) in clipboardStore.recentTexts(limit: 10).enumerated() {
            candidates.append(ContextCandidate(id: "hist-\(i)", kind: .clipboardHistory, text: item, isChecked: false))
        }

        let consoleState = ContextConsoleState(transcript: transcript, candidates: candidates)
        let panel = ContextConsolePanel(
            state: consoleState,
            onContinue: { [weak self] in
                guard let self else { return }
                // Trim the edited transcript FIRST: an empty transcript must not
                // record MRU or fire an LLM run — treat it like a cancel.
                let trimmed = consoleState.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.closeConsole()
                guard !trimmed.isEmpty else {
                    self.cleanupSessionState(dismissOverlay: true)
                    return
                }
                consoleState.isRunning = true
                let override = consoleState.assembleOverride()
                self.runPersona(persona, transcript: trimmed,
                                originatingApp: originatingApp, contextOverride: override)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.closeConsole()
                self.cleanupSessionState(dismissOverlay: true)
            }
        )
        consolePanel = panel
        panel.present()
    }

    private func failStart(_ message: String) {
        overlayPanel.showMessage(message)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.cleanupSessionState(dismissOverlay: true)
        }
    }

    private func maybeShowOCRPermissionToast() {
        let key = "windowOCRPermissionToastShown"
        if UserDefaults.standard.bool(forKey: key) { return }
        if WindowOCRProvider.hasScreenRecordingPermission() { return }
        UserDefaults.standard.set(true, forKey: key)
        overlayPanel.showTransientToast(
            String(localized: "Screen Recording permission needed for Window OCR"),
            durationSeconds: 4.0
        )
    }

    private func injectAfterPop(_ text: String, originatingApp: NSRunningApplication?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            OutputRouter.shared.activateOriginatingAppSync(originatingApp)
            self.textInjector.inject(text)
            NSSound(named: .init("Pop"))?.play()
        }
    }

    /// Tear down the context console if one is showing. Idempotent.
    private func closeConsole() {
        consolePanel?.orderOut(nil)
        consolePanel = nil
    }

    private func cleanupSessionState(dismissOverlay: Bool) {
        pickerPanel.dismiss()
        closeConsole()
        finalResultTimer?.invalidate()
        finalResultTimer = nil
        isRecording = false
        lastPartial = ""
        originatingApp = nil
        session?.release()
        session = nil
        if dismissOverlay {
            overlayPanel.dismiss()
        }
    }
}

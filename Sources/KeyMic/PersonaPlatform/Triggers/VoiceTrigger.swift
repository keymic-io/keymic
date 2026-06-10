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
    private let textInjector: TextInjector

    private var session: SpeechSession?
    private var isRecording = false
    private var lastPartial = ""
    private var finalResultTimer: Timer?
    private var runTask: Task<Void, Never>?
    private var originatingApp: NSRunningApplication?

    var isActive: Bool {
        isRecording || session != nil || finalResultTimer != nil || runTask != nil
    }

    init(engine: PersonaEngine,
         sessionHost: SpeechSessionHost,
         overlayPanel: OverlayPanel,
         personaStore: PersonaStore,
         textInjector: TextInjector) {
        self.engine = engine
        self.sessionHost = sessionHost
        self.overlayPanel = overlayPanel
        self.personaStore = personaStore
        self.textInjector = textInjector
    }

    func onTriggerDown() {
        guard !isActive else { return }
        do {
            let session = try sessionHost.acquire(client: self)
            self.session = session
            originatingApp = NSWorkspace.shared.frontmostApplication
            lastPartial = ""
            isRecording = true
            overlayPanel.show(text: "Listening...")
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
        overlayPanel.showMessage(msg)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.cleanupSessionState(dismissOverlay: true)
        }
    }

    func handleAudioLevel(_ level: Float) {
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

        guard let persona = personaStore.activePersona else {
            cleanupSessionState(dismissOverlay: true)
            injectAfterPop(transcript, originatingApp: originatingApp)
            return
        }

        if persona.contextSources.contains(.windowOCR) {
            maybeShowOCRPermissionToast()
        }

        let invocation = Invocation(
            persona: persona,
            transcript: transcript,
            originatingApp: originatingApp,
            outputOverride: nil
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

    private func cleanupSessionState(dismissOverlay: Bool) {
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

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
    private let currentFrontBundleID: () -> String?

    private var session: SpeechSession?
    private var isRecording = false
    private var lastPartial = ""
    private var finalResultTimer: Timer?
    private var runTask: Task<Void, Never>?
    private var originBundleID: String?

    init(engine: PersonaEngine,
         sessionHost: SpeechSessionHost,
         overlayPanel: OverlayPanel,
         personaStore: PersonaStore,
         textInjector: TextInjector,
         currentFrontBundleID: @escaping () -> String?) {
        self.engine = engine
        self.sessionHost = sessionHost
        self.overlayPanel = overlayPanel
        self.personaStore = personaStore
        self.textInjector = textInjector
        self.currentFrontBundleID = currentFrontBundleID
    }

    func onTriggerDown() {
        guard !isRecording else { return }
        do {
            session = try sessionHost.acquire(client: self)
        } catch {
            logger.info("Speech session busy; ignoring trigger down")
            return
        }
        originBundleID = currentFrontBundleID()
        lastPartial = ""
        isRecording = true
        overlayPanel.show(text: "Listening...")
        NSSound(named: .init("Tink"))?.play()
        session?.start()
    }

    func onTriggerUp() {
        guard isRecording else { return }
        isRecording = false
        session?.stop()
        finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    func onTriggerInterrupted() {
        guard isRecording else { return }
        isRecording = false
        finalResultTimer?.invalidate(); finalResultTimer = nil
        lastPartial = ""
        session?.cancel()
        session?.release()
        session = nil
        overlayPanel.dismiss()
    }

    // MARK: SpeechClient

    func handlePartial(_ text: String) {
        lastPartial = text
        overlayPanel.updateText(text)
    }

    func handleFinal(_ text: String) {
        lastPartial = text
        finalResultTimer?.invalidate(); finalResultTimer = nil
        finish()
    }

    func handleError(_ msg: String) {
        overlayPanel.updateText(msg)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.overlayPanel.dismiss()
            self.releaseSession()
        }
    }

    func handleAudioLevel(_ level: Float) {
        overlayPanel.updateAudioLevel(level)
    }

    // MARK: finish

    private func finish() {
        finalResultTimer?.invalidate(); finalResultTimer = nil
        let transcript = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            overlayPanel.dismiss()
            releaseSession()
            lastPartial = ""
            return
        }

        // Passthrough when no active persona.
        guard let persona = personaStore.activePersona else {
            overlayPanel.dismiss()
            injectAfterPop(transcript)
            releaseSession()
            lastPartial = ""
            return
        }

        let invocation = Invocation(
            persona: persona,
            fragments: [TextFragment(source: .voice, text: transcript, meta: [:])],
            originAppBundleID: originBundleID,
            outputOverride: nil
        )

        overlayPanel.showRefining()
        runTask = Task { [weak self] in
            guard let self else { return }
            defer { self.releaseSession() }
            do {
                let result = try await self.engine.run(invocation)
                switch result {
                case .injected:
                    await MainActor.run { self.overlayPanel.dismiss() }
                case .bypassed(.llmNotConfigured):
                    await MainActor.run {
                        self.overlayPanel.dismiss()
                        self.injectAfterPop(transcript)
                    }
                case .bypassed:
                    await MainActor.run { self.overlayPanel.dismiss() }
                }
            } catch InvocationError.cancelled {
                await MainActor.run { self.overlayPanel.dismiss() }
            } catch {
                logger.error("Persona run failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.overlayPanel.showMessage(String(localized: "Refine failed: \(error.localizedDescription)"))
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self.overlayPanel.dismiss()
                    self.injectAfterPop(transcript)
                }
            }
            await MainActor.run { self.lastPartial = "" }
        }
    }

    private func injectAfterPop(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textInjector.inject(text)
            NSSound(named: .init("Pop"))?.play()
        }
    }

    private func releaseSession() {
        session?.release()
        session = nil
    }
}

import AppKit
import Speech
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let secureInputMonitor = SecureInputMonitor()
    private let speechEngine: SpeechEngine = {
        let saved = UserDefaults.standard.string(forKey: AppDelegate.selectedLocaleCodeKey)
        let code: String
        if let saved, !saved.isEmpty {
            code = saved
        } else {
            code = AppDelegate.defaultSpeechLocaleCode()
            UserDefaults.standard.set(code, forKey: AppDelegate.selectedLocaleCodeKey)
        }
        return SpeechEngine(locale: Locale(identifier: code))
    }()
    private let textInjector = TextInjector()
    private let skillRegistry = SkillRegistry()
    private let skillLoader = SkillLoader()
    private let toolRegistry = ToolRegistry()
    private let mcpManager = MCPClientManager()
    /// Constructed inside `applicationDidFinishLaunching` because `AgentRunner.init`
    /// is `@MainActor`-isolated and stored-property initializers run in a
    /// nonisolated context. May be `nil` early in launch (before
    /// `registerLocalTools()` completes) or if construction was deferred — all
    /// consumers must tolerate absence and degrade gracefully.
    private var agentRunner: AgentRunner?
    private lazy var skillBridge = SkillHotkeyBridge(
        registry: skillRegistry,
        loader: skillLoader,
        consume: { [weak self] skill in
            // Plan 6: route skill hotkeys through the agent loop instead of
            // pasting the body directly. The skill's `instructions` become the
            // system prompt and `allowedTools` filters the tool set.
            guard let self = self else { return }
            Task { @MainActor in
                guard let runner = self.agentRunner else {
                    logger.warning("Skill hotkey fired but AgentRunner not ready; ignoring")
                    return
                }
                _ = runner.runForSkill(skill, sink: ConsoleSink.shared)
            }
        }
    )
    private lazy var actionRunner = HotkeyActionRunner(
        typeText: { [weak self] text in self?.textInjector.inject(text) },
        skillBridge: skillBridge,
        agentRunnerProvider: { [weak self] in
            // Re-resolved on every `.runAgent` invocation so an AgentRunner
            // that comes online after this runner is materialized is still
            // picked up.
            MainActor.assumeIsolated { self?.agentRunner }
        }
    )
    private lazy var overlayPanel = OverlayPanel()
    private var clipboardController: ClipboardController!
    private var screenshotController: ScreenshotController?

    private var voice = VoiceStateMachine()
    private var graceTimer: Timer?
    private var recordingTimeoutTimer: Timer?
    private static let recordingMaxDuration: TimeInterval = 6 * 60
    private static let graceDuration: TimeInterval = 2.0
    private var singleInstanceLockURL: URL?
    private var personaObserverToken: NSObjectProtocol?

    /// Cached frontmost-app bundle ID. Updated via `NSWorkspace.didActivateApplicationNotification`.
    /// KeyMonitor's event-tap callback reads this O(1); calling
    /// `NSWorkspace.shared.frontmostApplication` directly in the callback can stall
    /// LaunchServices for hundreds of ms and trigger the 1s tap-disable timeout
    /// (which presents as system-wide kbd/mouse freezes).
    private var cachedFrontBundleID: String?

    private static let voiceEnabledKey = "voiceEnabled"
    private static let selectedLocaleCodeKey = "selectedLocaleCode"
    private static let clipboardSchemaVersionKey = "clipboardSchemaVersion"
    private static let clipboardSchemaVersion = 2

    private var voiceEnabledMenuTitle: String { String(localized: "Voice Enabled") }
    private(set) var isVoiceEnabled: Bool =
        UserDefaults.standard.object(forKey: AppDelegate.voiceEnabledKey) as? Bool ?? true

    private var voiceEnabledMenuItem: NSMenuItem!
    private var personasRootMenuItem: NSMenuItem!
    private var personasMenu: NSMenu?
    private var keyMappingMenuItem: NSMenuItem!
    private var clipboardMenuItem: NSMenuItem!
    private var shortcutsMenuItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!
    private lazy var settingsWindow = SwiftUISettingsWindow(
        agentRunnerProvider: { [weak self] in self?.agentRunner },
        toolRegistry: toolRegistry
    )
    var selectedLocaleCode: String {
        get { UserDefaults.standard.string(forKey: Self.selectedLocaleCodeKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.selectedLocaleCodeKey) }
    }

    /// Pick a speech locale identifier matching the system language on first launch.
    /// `Locale.current.identifier` uses `en_US` but `SFSpeechRecognizer.supportedLocales()`
    /// emits `en-US`, so a raw fall-back to `Locale.current` would leave the Picker empty.
    static func defaultSpeechLocaleCode() -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        let supportedIDs = Set(supported.map { $0.identifier })

        let candidates: [String] = (Locale.preferredLanguages + [Locale.current.identifier])
        for candidate in candidates {
            if supportedIDs.contains(candidate) { return candidate }
            let dashed = candidate.replacingOccurrences(of: "_", with: "-")
            if supportedIDs.contains(dashed) { return dashed }
        }

        let systemLang = Locale.current.language.languageCode?.identifier
        if let systemLang,
            let match = supported.first(where: { $0.language.languageCode?.identifier == systemLang })
        {
            return match.identifier
        }
        return "en-US"
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() { return }

        AppScreen.refresh()

        setupMainMenu()
        setupStatusBar()
        setupSpeechCallbacks()

        SpeechEngine.requestPermissions { [weak self] granted, errorMsg in
            if !granted, let msg = errorMsg {
                self?.showAlert(title: String(localized: "Permission Required"), message: msg)
            }
        }

        cachedFrontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if !AXIsProcessTrusted() {
            showAccessibilityAlert()
            return
        }
        if !keyMonitor.start() {
            showAccessibilityAlert()
            return
        }
        keyMonitor.currentFrontBundleID = { [weak self] in self?.cachedFrontBundleID }

        keyMonitor.onTriggerDown = { [weak self] in self?.triggerDown() }
        keyMonitor.onTriggerUp = { [weak self] in self?.triggerUp() }
        keyMonitor.onTriggerInterrupted = { [weak self] in self?.cancelRecording() }
        keyMonitor.onExtraneousKeyDuringVoice = { [weak self] in self?.extraneousKeyDuringVoice() }
        keyMonitor.isVoiceActive = { [weak self] in self?.voice.state.isActive ?? false }
        // Wire `onAction` synchronously right after `keyMonitor.start()` so a
        // hotkey pressed during the first ~10–100ms of launch isn't matched by
        // the tap (consuming the keystroke) only to then dispatch into a nil
        // `onAction`. `actionRunner` resolves `agentRunner` lazily via
        // `agentRunnerProvider`, so it's safe to wire before the runtime is
        // fully constructed.
        keyMonitor.onAction = { [weak self] actions in self?.actionRunner.run(actions) }

        Task { @MainActor in
            await registerLocalTools()
            agentRunner = AgentRunner(registry: toolRegistry, skillRegistry: skillRegistry)
            Task { [mcpManager, toolRegistry] in
                await mcpManager.loadAndConnectAll(registry: toolRegistry)
            }
        }

        clipboardController = ClipboardController()
        clipboardController.overlayPanel = overlayPanel

        let installedVersion = UserDefaults.standard.integer(forKey: Self.clipboardSchemaVersionKey)
        if installedVersion < Self.clipboardSchemaVersion {
            logger.info("Clipboard schema upgrade to v\(Self.clipboardSchemaVersion): wiping legacy ClipboardItem rows")
            clipboardController.performSchemaWipe()
            UserDefaults.standard.set(Self.clipboardSchemaVersion, forKey: Self.clipboardSchemaVersionKey)
        } else {
            clipboardController.sweepOrphanCacheFiles()
        }

        textInjector.onMarkIgnored = { [weak self] text in
            self?.clipboardController.markPasteboardWrite(text)
        }
        keyMonitor.onClipboardHotkey = { [weak self] in self?.clipboardController.toggle() }
        keyMonitor.onVaultHotkey = { [weak self] in
            self?.clipboardController.toggle(initialTab: .vault)
        }
        keyMonitor.onClipboardQuickPaste = { [weak self] index in self?.clipboardController.quickPaste(index: index) }
        keyMonitor.isClipboardPanelVisible = { [weak self] in self?.clipboardController.isPanelVisible == true }
        keyMonitor.onSettingsHotkey = { [weak self] in self?.openSettings() }
        screenshotController = ScreenshotController()
        keyMonitor.onScreenshotHotkey = { [weak self] in self?.screenshotController?.start() }
        secureInputMonitor.onEnter = { [weak self] in self?.keyMonitor.onSecureInputEnter() }
        secureInputMonitor.onExit = { [weak self] in self?.keyMonitor.onSecureInputExit() }
        secureInputMonitor.start()
        clipboardController.start()
        _ = UpdaterController.shared

        HotkeySettingsStore.shared.ensureInitialized()

        // Register built-in hotkeys with HotkeyRegistry so persona recorder can detect conflicts.
        let registry = HotkeyRegistry.shared
        let hotkeys = HotkeySettingsStore.shared
        let builtIns: [(HotkeyFeature, HotkeyRegistry.Owner, String)] = [
            (.voiceTrigger, .voiceTrigger, "Voice trigger"),
            (.clipboardPanel, .clipboardPanel, "Clipboard panel"),
            (.vaultPanel, .vaultPanel, "Vault panel"),
            (.settingsWindow, .settingsWindow, "Settings window"),
            (.screenshot, .screenshot, "Screenshot"),
        ]
        for (feature, owner, purpose) in builtIns {
            if let cfg = hotkeys.hotkey(for: feature) {
                registry.register(cfg, owner: owner, purpose: purpose)
            }
        }
        AppDelegate.syncPersonaHotkeysToRegistry()
        personaObserverToken = NotificationCenter.default.addObserver(
            forName: PersonaStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            AppDelegate.syncPersonaHotkeysToRegistry()
            self?.rebuildPersonasMenu()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncMenuStates),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        ShellRunner.shared.warmUp()
    }

    static func syncPersonaHotkeysToRegistry() {
        let registry = HotkeyRegistry.shared
        let hotkeys = HotkeySettingsStore.shared
        hotkeys.ensureInitialized()
        for entry in registry.all() {
            if case .persona = entry.owner { registry.unregister(owner: entry.owner) }
        }
        for persona in PersonaStore.shared.personas {
            guard let cfg = hotkeys.personaHotkey(personaId: persona.id) else { continue }
            registry.register(cfg, owner: .persona(id: persona.id), purpose: "Persona: \(persona.name)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HIDRemapper.reset()
        if let token = personaObserverToken {
            NotificationCenter.default.removeObserver(token)
            personaObserverToken = nil
        }
        if let singleInstanceLockURL {
            SingleInstance.releaseLock(at: singleInstanceLockURL)
        }
    }

    private func activateExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        if let lockURL = SingleInstance.acquireLock(bundleIdentifier: bundleIdentifier) {
            singleInstanceLockURL = lockURL
            return false
        }
        if let existing = SingleInstance.existingInstance(bundleIdentifier: bundleIdentifier),
            let app = NSRunningApplication(processIdentifier: existing.processIdentifier)
        {
            app.activate(options: [])
        }
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Key events

    private func triggerDown() {
        guard isVoiceEnabled else { return }
        guard !voice.state.isListening else { return }
        LLMRefiner.shared.cancel()
        do {
            let session = try speechEngine.startSession()
            let effects = voice.handle(.triggerDown(session: session))
            apply(effects)
        } catch let err as VoiceError {
            apply(voice.handle(.error(err)))
        } catch {
            apply(voice.handle(.error(.audioEngineFailed(error.localizedDescription))))
        }
    }

    private func triggerUp() {
        guard voice.state.isActive else { return }
        speechEngine.endAudio()
        apply(voice.handle(.triggerUp))
    }

    private func cancelRecording() {
        guard voice.state.isActive else { return }
        apply(voice.handle(.extraneousKey))
    }

    private func extraneousKeyDuringVoice() {
        guard voice.state.isActive else { return }
        apply(voice.handle(.extraneousKey))
    }

    private func apply(_ effects: [VoiceSideEffect]) {
        for e in effects {
            switch e {
            case .cancelSession(let s):
                s.cancel()
            case .stopAudio(_):
                speechEngine.endAudio()
            case .startGraceTimer:
                graceTimer?.invalidate()
                graceTimer = Timer.scheduledTimer(withTimeInterval: Self.graceDuration, repeats: false) { [weak self] _ in
                    self?.apply(self?.voice.handle(.graceTimeout) ?? [])
                }
            case .cancelGraceTimer:
                graceTimer?.invalidate(); graceTimer = nil
            case .startRecordingTimeoutTimer(_):
                recordingTimeoutTimer?.invalidate()
                recordingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.recordingMaxDuration, repeats: false) { [weak self] _ in
                    self?.apply(self?.voice.handle(.recordingTimeout) ?? [])
                }
            case .cancelRecordingTimeoutTimer:
                recordingTimeoutTimer?.invalidate(); recordingTimeoutTimer = nil
            case .updateStatusIcon(let on):
                updateStatusIcon(recording: on)
            case .overlayShow(let t):
                overlayPanel.show(text: t)
            case .overlayUpdate(let t):
                overlayPanel.updateText(t)
            case .overlayShowRefining:
                overlayPanel.showRefining()
            case .overlayDismiss:
                overlayPanel.dismiss()
            case .overlayShowError(let err):
                overlayPanel.showMessage(err.displayMessage)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.overlayPanel.dismiss() }
            case .injectAndFinish(let text):
                finishTranscription(text: text)
            case .playSound(let name):
                NSSound(named: .init(name))?.play()
            case .bufferPartial, .clearPartial:
                break  // lastPartial lives in the reducer; runtime doesn't duplicate it
            }
        }
    }

    // MARK: - Speech callbacks

    private func setupSpeechCallbacks() {
        speechEngine.onPartialResult = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                self?.apply(self?.voice.handle(.partialResult(text)) ?? [])
            }
        }
        speechEngine.onFinalResult = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                self?.apply(self?.voice.handle(.finalResult(text)) ?? [])
            }
        }
        speechEngine.onError = { [weak self] msg in
            DispatchQueue.main.async { [weak self] in
                self?.apply(self?.voice.handle(.error(.audioEngineFailed(msg))) ?? [])
            }
        }
        speechEngine.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }
        speechEngine.onLocaleUnavailable = { [weak self] msg in
            DispatchQueue.main.async { [weak self] in
                self?.showAlert(title: String(localized: "Language Unavailable"), message: msg)
            }
        }
    }

    private func finishTranscription(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { overlayPanel.dismiss(); return }

        let persona = PersonaStore.shared.activePersona
        let refiner = LLMRefiner.shared
        guard let persona, refiner.isReady else {
            overlayPanel.dismiss()
            injectAfterPop(trimmed)
            return
        }

        let userText = buildUserText(transcript: trimmed, contextMode: persona.contextMode)
        overlayPanel.showRefining()
        refiner.refine(userText, systemPrompt: persona.stylePrompt, temperature: persona.temperature) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let refined):
                let finalText = refined.isEmpty ? trimmed : refined
                self.overlayPanel.dismiss()
                self.injectAfterPop(finalText)
            case .failure(let error):
                logger.error("Refine failed: \(error.localizedDescription, privacy: .public)")
                self.overlayPanel.showMessage(String(localized: "Refine failed: \(error.localizedDescription)"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.overlayPanel.dismiss()
                    self?.injectAfterPop(trimmed)
                }
            }
        }
    }

    /// Builds the LLM user prompt, injecting selected text + clipboard as context
    /// when the persona's contextMode is `.selectionAndClipboard`.
    private func buildUserText(transcript: String, contextMode: ContextMode) -> String {
        guard contextMode == .selectionAndClipboard else { return transcript }

        let selection =
            SelectionTextProvider.currentSelection()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clipboard =
            NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var sections: [String] = []
        var includeTranscript = true

        if !selection.isEmpty {
            sections.append("[Selected text]\n\(selection)")
            if transcript == selection || selection.utf16.count > 2000 {
                includeTranscript = false
            }
        }
        if !clipboard.isEmpty && clipboard != selection {
            sections.append("[Recent clipboard]\n\(clipboard)")
        }
        if includeTranscript {
            sections.append("[User said]\n\(transcript)")
        }

        let result = sections.joined(separator: "\n\n")
        // Cap at 7500 UTF-16 units, snapped to character boundary (avoids splitting surrogate pairs).
        if result.utf16.count > 7500 {
            var trimmed = ""
            for ch in result {
                if trimmed.utf16.count + ch.utf16.count > 7500 { break }
                trimmed.append(ch)
            }
            return trimmed
        }
        return result
    }

    private func injectAfterPop(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textInjector.inject(text)
            NSSound(named: .init("Pop"))?.play()
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editMenu = NSMenu()
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: String(localized: "Edit"), action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        voiceEnabledMenuItem = NSMenuItem(
            title: voiceEnabledMenuTitle, action: #selector(toggleVoiceEnabled), keyEquivalent: "")
        voiceEnabledMenuItem.target = self
        voiceEnabledMenuItem.state = isVoiceEnabled ? .on : .off
        voiceEnabledMenuItem.image = symbolImage("mic.fill")
        applyVoiceShortcut(to: voiceEnabledMenuItem)
        menu.addItem(voiceEnabledMenuItem)

        personasRootMenuItem = NSMenuItem(title: String(localized: "Default Persona"), action: nil, keyEquivalent: "")
        personasRootMenuItem.image = symbolImage("person.crop.circle.badge.checkmark")
        let personasMenu = NSMenu()
        personasRootMenuItem.submenu = personasMenu
        self.personasMenu = personasMenu
        rebuildPersonasMenu()
        menu.addItem(personasRootMenuItem)

        menu.addItem(.separator())

        keyMappingMenuItem = NSMenuItem(title: String(localized: "Key Mapping"), action: #selector(toggleKeyMapping), keyEquivalent: "")
        keyMappingMenuItem.target = self
        keyMappingMenuItem.state = KeyMappingManager.shared.isEnabled ? .on : .off
        keyMappingMenuItem.image = symbolImage("keyboard")
        menu.addItem(keyMappingMenuItem)

        clipboardMenuItem = NSMenuItem(
            title: String(localized: "Clipboard History"), action: #selector(toggleClipboard), keyEquivalent: "")
        clipboardMenuItem.target = self
        clipboardMenuItem.state = ClipboardPreferences.enabled ? .on : .off
        clipboardMenuItem.image = symbolImage("doc.on.clipboard")
        menu.addItem(clipboardMenuItem)

        shortcutsMenuItem = NSMenuItem(title: String(localized: "Shortcuts"), action: #selector(toggleShortcuts), keyEquivalent: "")
        shortcutsMenuItem.target = self
        shortcutsMenuItem.state = HotkeyPreferences.enabled ? .on : .off
        shortcutsMenuItem.image = symbolImage("bolt.horizontal")
        menu.addItem(shortcutsMenuItem)

        settingsMenuItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: "")
        settingsMenuItem.target = self
        settingsMenuItem.image = symbolImage("gearshape")
        applySettingsShortcut(to: settingsMenuItem)
        menu.addItem(settingsMenuItem)

        menu.addItem(.separator())

        let checkUpdateItem = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdateItem.target = self
        checkUpdateItem.image = symbolImage("arrow.down.circle")
        menu.addItem(checkUpdateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit KeyMic"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = symbolImage("power")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return image?.withSymbolConfiguration(config)
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "KeyMic")
            button.contentTintColor = .systemRed
        } else {
            button.image = idleTrayImage ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "KeyMic")
            button.contentTintColor = nil
        }
    }

    private lazy var idleTrayImage: NSImage? = {
        let pointSize: CGFloat = 22
        let image = NSImage()
        for name in ["TrayIconTemplate", "TrayIconTemplate@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                let rep = NSImageRep(contentsOf: url)
            else { continue }
            rep.size = NSSize(width: pointSize, height: pointSize)
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        return image
    }()

    // MARK: - Actions

    @objc private func toggleVoiceEnabled() {
        setVoiceEnabled(!isVoiceEnabled)
    }

    func setVoiceEnabled(_ enabled: Bool) {
        guard enabled != isVoiceEnabled else { return }
        isVoiceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.voiceEnabledKey)
        voiceEnabledMenuItem.state = enabled ? .on : .off

        if !enabled, voice.state.isActive {
            apply(voice.handle(.voiceDisabled))
        }
    }

    @objc private func toggleKeyMapping() {
        let manager = KeyMappingManager.shared
        manager.isEnabled.toggle()
        keyMappingMenuItem.state = manager.isEnabled ? .on : .off
    }

    @objc private func toggleClipboard() {
        let newValue = !ClipboardPreferences.enabled
        UserDefaults.standard.set(newValue, forKey: ClipboardPreferences.enabledKey)
        clipboardMenuItem.state = newValue ? .on : .off
    }

    @objc private func toggleShortcuts() {
        let newValue = !HotkeyPreferences.enabled
        UserDefaults.standard.set(newValue, forKey: HotkeyPreferences.enabledKey)
        shortcutsMenuItem.state = newValue ? .on : .off
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        cachedFrontBundleID = app?.bundleIdentifier
    }

    @objc private func syncMenuStates() {
        // Mirror runtime state from UserDefaults whenever any preference changes
        // (SwiftUI Settings writes directly via @AppStorage).
        clipboardMenuItem.state = ClipboardPreferences.enabled ? .on : .off
        shortcutsMenuItem.state = HotkeyPreferences.enabled ? .on : .off
        keyMappingMenuItem.state = KeyMappingManager.shared.isEnabled ? .on : .off
        applySettingsShortcut(to: settingsMenuItem)

        let defaultsVoice = UserDefaults.standard.object(forKey: Self.voiceEnabledKey) as? Bool ?? true
        if defaultsVoice != isVoiceEnabled {
            setVoiceEnabled(defaultsVoice)
        }

        let code = selectedLocaleCode
        let newLocale = code.isEmpty ? Locale.current : Locale(identifier: code)
        if speechEngine.locale.identifier != newLocale.identifier {
            speechEngine.locale = newLocale
        }

        applyVoiceShortcut(to: voiceEnabledMenuItem)
        rebuildPersonasMenu()

        // Voice trigger key may have changed — clear any stuck trigger state.
        keyMonitor.resetAllInputState(reason: .settingsReload)
    }

    private func applyVoiceShortcut(to item: NSMenuItem) {
        guard let cfg = HotkeySettingsStore.shared.hotkey(for: .voiceTrigger) else {
            item.title = voiceEnabledMenuTitle
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        let rep = cfg.menuRepresentation
        if rep.key.isEmpty {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            item.title = "\(voiceEnabledMenuTitle)\t\(cfg.displayString())"
            return
        }

        item.title = voiceEnabledMenuTitle
        item.keyEquivalent = rep.key
        item.keyEquivalentModifierMask = rep.modifiers
    }

    private func rebuildPersonasMenu() {
        guard let personasMenu else { return }
        let personas = PersonaStore.shared.personas

        // Fast path: if persona identity + title + hotkey are unchanged, just redraw
        // existing views (preserves NSMenu tracking state while the submenu is open).
        let existing = personasMenu.items.compactMap { $0.view as? PersonaMenuItemView }
        if existing.count == personas.count,
           zip(existing, personas).allSatisfy({ $0.personaId == $1.id }) {
            existing.forEach { $0.needsDisplay = true }
            return
        }

        personasMenu.removeAllItems()
        for persona in personas {
            let pid = persona.id
            let hotkeyText = HotkeySettingsStore.shared
                .personaHotkey(personaId: pid)?
                .displayString()
            let view = PersonaMenuItemView(
                personaId: pid,
                title: persona.name,
                hotkeyText: hotkeyText
            ) { [weak self] in
                self?.togglePersona(id: pid)
            }
            let item = NSMenuItem()
            item.representedObject = pid
            item.view = view
            personasMenu.addItem(item)
        }
    }

    private func togglePersona(id: String) {
        let store = PersonaStore.shared
        if store.activePersonaId == id {
            store.setActive(nil)
        } else {
            store.setActive(id)
        }
    }

    private func applySettingsShortcut(to item: NSMenuItem) {
        guard let cfg = HotkeySettingsStore.shared.hotkey(for: .settingsWindow) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        let rep = cfg.menuRepresentation
        item.keyEquivalent = rep.key
        item.keyEquivalentModifierMask = rep.modifiers
    }

    @objc private func openSettings() {
        let needsCenter = !settingsWindow.isVisible
        if needsCenter {
            // Pin to a known size first; SwiftUI's NSHostingController can
            // resize the window after order-front, which races our centering
            // and drops it in the bottom-right on first launch.
            settingsWindow.setContentSize(NSSize(width: 760, height: 540))
            centerSettingsWindowOnActiveScreen()
        }
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Re-center on next runloop tick after SwiftUI has finished its
        // (possibly size-changing) layout pass.
        if needsCenter {
            DispatchQueue.main.async { [weak self] in
                self?.centerSettingsWindowOnActiveScreen()
            }
        }
    }

    private func centerSettingsWindowOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            settingsWindow.center()
            return
        }
        let size = settingsWindow.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        settingsWindow.setFrameOrigin(origin)
    }

    @objc private func quit() {
        secureInputMonitor.stop()
        keyMonitor.stop()
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Accessibility Permission Required")
        alert.informativeText = String(localized: "KeyMic needs Accessibility permission to monitor configured hotkeys and apply key mappings.\n\n1. Open System Settings → Privacy & Security → Accessibility\n2. Add and enable KeyMic\n3. Restart the app")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Quit"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Register the built-in (in-process) tools into `toolRegistry`. MCP-discovered
    /// tools arrive asynchronously via `MCPClientManager.loadAndConnectAll`.
    private func registerLocalTools() async {
        let tools: [any Tool] = [
            BashTool(),
            ReadTool(),
            WriteTool(),
            EditTool(),
            MultiEditTool(),
            GlobTool(),
            GrepTool(),
            ActivateSkillTool(registry: skillRegistry, loader: skillLoader),
        ]
        do {
            try await LocalToolRegistrar.register(tools, in: toolRegistry)
        } catch {
            logger.error("Failed to register local tools: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - HotkeyConfig → NSMenuItem

extension HotkeyConfig {
    /// Convert this hotkey to an NSMenuItem keyEquivalent + modifier mask so the
    /// shortcut shows next to the menu item title (e.g. "⇧⌘,").
    fileprivate var menuRepresentation: (key: String, modifiers: NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = []
        if modifiers.contains(.maskCommand) { mods.insert(.command) }
        if modifiers.contains(.maskShift) { mods.insert(.shift) }
        if modifiers.contains(.maskControl) { mods.insert(.control) }
        if modifiers.contains(.maskAlternate) { mods.insert(.option) }
        if modifiers.contains(.maskSecondaryFn) { mods.insert(.function) }

        let key: String
        switch keyCode {
        case 0x35: key = "\u{1B}"  // ⎋
        case 0x24: key = "\r"  // ↩
        case 0x33: key = "\u{8}"  // ⌫
        case 0x30: key = "\t"  // ⇥
        case 0x31: key = " "  // Space
        case 0x7B: key = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case 0x7C: key = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case 0x7D: key = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case 0x7E: key = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        default:
            if let token = HotkeyConfig.tokenToKeyCode.first(where: { $0.value == keyCode })?.key,
                token.count == 1
            {
                key = token
            } else {
                key = ""
            }
        }
        return (key, mods)
    }
}

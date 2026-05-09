import AppKit
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let speechEngine: SpeechEngine = {
        let saved = UserDefaults.standard.string(forKey: "selectedLocaleCode")
        let code: String
        if let saved, !saved.isEmpty {
            code = saved
        } else {
            // First launch: derive from system language and persist it.
            code = AppDelegate.defaultSpeechLocaleCode()
            UserDefaults.standard.set(code, forKey: "selectedLocaleCode")
        }
        return SpeechEngine(locale: Locale(identifier: code))
    }()
    private let textInjector = TextInjector()
    private lazy var actionRunner = HotkeyActionRunner(
        typeText: { [weak self] text in self?.textInjector.inject(text) }
    )
    private lazy var overlayPanel = OverlayPanel()
    private var clipboardController: ClipboardController!
    private var screenshotController: ScreenshotController?

    private var isRecording = false
    private var lastPartialResult = ""
    private var finalResultTimer: Timer?
    private var singleInstanceLockURL: URL?

    /// Cached frontmost-app bundle ID. Updated via `NSWorkspace.didActivateApplicationNotification`.
    /// KeyMonitor's event-tap callback reads this O(1); calling
    /// `NSWorkspace.shared.frontmostApplication` directly in the callback can stall
    /// LaunchServices for hundreds of ms and trigger the 1s tap-disable timeout
    /// (which presents as system-wide kbd/mouse freezes).
    private var cachedFrontBundleID: String?

    private let voiceEnabledKey = "voiceEnabled"
    private let voiceEnabledMenuTitle = "Voice Enabled"
    private(set) var isVoiceEnabled: Bool = UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true

    private var voiceEnabledMenuItem: NSMenuItem!
    private var personasRootMenuItem: NSMenuItem!
    private var personasMenu: NSMenu?
    private var keyMappingMenuItem: NSMenuItem!
    private var clipboardMenuItem: NSMenuItem!
    private var shortcutsMenuItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!
    private lazy var settingsWindow = SwiftUISettingsWindow()
    var selectedLocaleCode: String {
        get { UserDefaults.standard.string(forKey: "selectedLocaleCode") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLocaleCode") }
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
           let match = supported.first(where: { $0.language.languageCode?.identifier == systemLang }) {
            return match.identifier
        }
        return "en-US"
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() { return }

        AppScreen.refresh()

        let savedCode = selectedLocaleCode
        speechEngine.locale = savedCode.isEmpty ? Locale(identifier: Self.defaultSpeechLocaleCode()) : Locale(identifier: savedCode)

        setupMainMenu()
        setupStatusBar()
        setupSpeechCallbacks()

        SpeechEngine.requestPermissions { [weak self] granted, errorMsg in
            if !granted, let msg = errorMsg {
                self?.showAlert(title: "Permission Required", message: msg)
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
        keyMonitor.onAction = { [weak self] actions in self?.actionRunner.run(actions) }
        clipboardController = ClipboardController()
        clipboardController.overlayPanel = overlayPanel
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
        clipboardController.start()
        _ = UpdaterController.shared

        // Register built-in hotkeys with HotkeyRegistry so persona recorder can detect conflicts.
        let registry = HotkeyRegistry.shared
        let triggerRaw = UserDefaults.standard.string(forKey: "voiceTriggerKey") ?? "fn"
        if let cfg = HotkeyConfig.parse(triggerRaw) {
            registry.register(cfg, owner: .voiceTrigger, purpose: "Voice trigger")
        }
        let clipRaw = UserDefaults.standard.string(forKey: "clipboardHotkey") ?? "alt+v"
        if let clipCfg = HotkeyConfig.parse(clipRaw) {
            registry.register(clipCfg, owner: .clipboardPanel, purpose: "Clipboard panel (⌥V)")
        }
        AppDelegate.syncPersonaHotkeysToRegistry()
        NotificationCenter.default.addObserver(
            forName: PersonaStore.didChangeNotification, object: nil, queue: .main
        ) { _ in AppDelegate.syncPersonaHotkeysToRegistry() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncMenuStates),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    static func syncPersonaHotkeysToRegistry() {
        let registry = HotkeyRegistry.shared
        for entry in registry.all() {
            if case .persona = entry.owner { registry.unregister(owner: entry.owner) }
        }
        for persona in PersonaStore.shared.personas {
            guard let raw = persona.hotkey, let cfg = HotkeyConfig.parse(raw) else { continue }
            registry.register(cfg, owner: .persona(id: persona.id), purpose: "Persona: \(persona.name)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HIDRemapper.reset()
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
           let app = NSRunningApplication(processIdentifier: existing.processIdentifier) {
            app.activate(options: [])
        }
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Key events

    private func triggerDown() {
        guard isVoiceEnabled, !isRecording else { return }
        LLMRefiner.shared.cancel()
        isRecording = true
        lastPartialResult = ""

        updateStatusIcon(recording: true)
        overlayPanel.show(text: "Listening...")
        NSSound(named: .init("Tink"))?.play()

        speechEngine.startRecording()
    }

    private func triggerUp() {
        guard isRecording else { return }
        isRecording = false

        updateStatusIcon(recording: false)
        speechEngine.stopRecording()

        finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.finishTranscription()
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        finalResultTimer?.invalidate()
        finalResultTimer = nil
        lastPartialResult = ""
        speechEngine.cancel()
        updateStatusIcon(recording: false)
        overlayPanel.dismiss()
    }

    // MARK: - Speech callbacks

    private func setupSpeechCallbacks() {
        speechEngine.onPartialResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.overlayPanel.updateText(text)
        }

        speechEngine.onFinalResult = { [weak self] text in
            guard let self else { return }
            self.lastPartialResult = text
            self.finalResultTimer?.invalidate()
            self.finalResultTimer = nil
            self.finishTranscription()
        }

        speechEngine.onError = { [weak self] msg in
            guard let self else { return }
            guard !self.lastPartialResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.overlayPanel.dismiss()
                return
            }
            self.overlayPanel.updateText("Error: \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.overlayPanel.dismiss()
            }
        }

        speechEngine.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }

        speechEngine.onLocaleUnavailable = { [weak self] msg in
            self?.showAlert(title: "Language Unavailable", message: msg)
        }
    }

    private func finishTranscription() {
        finalResultTimer?.invalidate()
        finalResultTimer = nil

        let text = lastPartialResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            overlayPanel.dismiss()
            lastPartialResult = ""
            return
        }

        let persona = PersonaStore.shared.activePersona
        let refiner = LLMRefiner.shared

        // Passthrough: no active persona, or LLM endpoint not configured (silent, no toast).
        guard let persona, refiner.isReady else {
            if persona != nil {
                NSLog("[Persona] LLM not ready; passthrough")
            }
            overlayPanel.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.textInjector.inject(text)
                NSSound(named: .init("Pop"))?.play()
            }
            lastPartialResult = ""
            return
        }

        let userText = buildUserText(transcript: text, contextMode: persona.contextMode)

        overlayPanel.showRefining()
        refiner.refine(userText, systemPrompt: persona.stylePrompt, temperature: persona.temperature) { [weak self] result in
            guard let self else { return }
            let finalText: String
            switch result {
            case .success(let refined):
                finalText = refined.isEmpty ? text : refined
                let wasRefined = finalText != text
                if wasRefined {
                    self.overlayPanel.updateText("✨ \(finalText)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.overlayPanel.dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.textInjector.inject(finalText)
                            NSSound(named: .init("Pop"))?.play()
                        }
                    }
                } else {
                    self.overlayPanel.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.textInjector.inject(finalText)
                        NSSound(named: .init("Pop"))?.play()
                    }
                }
            case .failure(let error):
                NSLog("[LLMRefiner] Refine failed: %@", error.localizedDescription)
                finalText = text
                self.overlayPanel.updateText("Refine failed: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.overlayPanel.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.textInjector.inject(finalText)
                        NSSound(named: .init("Pop"))?.play()
                    }
                }
            }
            self.lastPartialResult = ""
        }
    }

    /// Builds the LLM user prompt, injecting selected text + clipboard as context
    /// when the persona's contextMode is `.selectionAndClipboard`.
    private func buildUserText(transcript: String, contextMode: ContextMode) -> String {
        guard contextMode == .selectionAndClipboard else { return transcript }

        let selection = SelectionTextProvider.currentSelection()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var sections: [String] = []
        var includeTranscript = true

        if !selection.isEmpty {
            sections.append("[Selected text]\n\(selection)")
            // Omit [User said] if transcript equals selected text (redundant).
            if transcript == selection {
                includeTranscript = false
            }
            // Omit [User said] if selected text exceeds 2000 UTF-16 units.
            if selection.utf16.count > 2000 {
                includeTranscript = false
            }
        }
        // Omit clipboard if identical to selection (avoid redundancy).
        if !clipboard.isEmpty && clipboard != selection {
            sections.append("[Recent clipboard]\n\(clipboard)")
        }
        if includeTranscript {
            sections.append("[User said]\n\(transcript)")
        }

        var result = sections.joined(separator: "\n\n")
        // Cap total output at 7500 UTF-16 units, truncating from end.
        if result.utf16.count > 7500 {
            let units = result.utf16
            let cutIdx = units.index(units.startIndex, offsetBy: 7500)
            result = String(units[units.startIndex..<cutIdx]) ?? String(result[..<result.unicodeScalars.index(result.startIndex, offsetBy: 7500)])
        }
        return result
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Edit menu with standard text editing commands
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        // Group 1: Voice + Personas
        voiceEnabledMenuItem = NSMenuItem(title: voiceEnabledMenuTitle, action: #selector(toggleVoiceEnabled), keyEquivalent: "")
        voiceEnabledMenuItem.target = self
        voiceEnabledMenuItem.state = isVoiceEnabled ? .on : .off
        voiceEnabledMenuItem.image = symbolImage("mic.fill")
        applyVoiceShortcut(to: voiceEnabledMenuItem)
        menu.addItem(voiceEnabledMenuItem)

        personasRootMenuItem = NSMenuItem(title: "Personas", action: nil, keyEquivalent: "")
        personasRootMenuItem.image = symbolImage("person.crop.circle.badge.checkmark")
        let personasMenu = NSMenu()
        personasRootMenuItem.submenu = personasMenu
        self.personasMenu = personasMenu
        rebuildPersonasMenu()
        menu.addItem(personasRootMenuItem)

        menu.addItem(.separator())

        // Group 2: Key mapping + Clipboard + Shortcuts
        keyMappingMenuItem = NSMenuItem(title: "Key Mapping", action: #selector(toggleKeyMapping), keyEquivalent: "")
        keyMappingMenuItem.target = self
        keyMappingMenuItem.state = KeyMappingManager.shared.isEnabled ? .on : .off
        keyMappingMenuItem.image = symbolImage("keyboard")
        menu.addItem(keyMappingMenuItem)

        clipboardMenuItem = NSMenuItem(title: "Clipboard History", action: #selector(toggleClipboard), keyEquivalent: "")
        clipboardMenuItem.target = self
        clipboardMenuItem.state = ClipboardPreferences.enabled ? .on : .off
        clipboardMenuItem.image = symbolImage("doc.on.clipboard")
        menu.addItem(clipboardMenuItem)

        shortcutsMenuItem = NSMenuItem(title: "Shortcuts", action: #selector(toggleShortcuts), keyEquivalent: "")
        shortcutsMenuItem.target = self
        shortcutsMenuItem.state = HotkeyPreferences.enabled ? .on : .off
        shortcutsMenuItem.image = symbolImage("bolt.horizontal")
        menu.addItem(shortcutsMenuItem)

        settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
        settingsMenuItem.target = self
        settingsMenuItem.image = symbolImage("gearshape")
        applySettingsShortcut(to: settingsMenuItem)
        menu.addItem(settingsMenuItem)

        menu.addItem(.separator())

        let checkUpdateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdateItem.target = self
        checkUpdateItem.image = symbolImage("arrow.down.circle")
        menu.addItem(checkUpdateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit KeyMic", action: #selector(quit), keyEquivalent: "q")
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
                  let rep = NSImageRep(contentsOf: url) else { continue }
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
        UserDefaults.standard.set(enabled, forKey: voiceEnabledKey)
        voiceEnabledMenuItem.state = enabled ? .on : .off

        if !enabled, isRecording {
            speechEngine.cancel()
            overlayPanel.dismiss()
            isRecording = false
            updateStatusIcon(recording: false)
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

        let defaultsVoice = UserDefaults.standard.object(forKey: voiceEnabledKey) as? Bool ?? true
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
        keyMonitor.resetTriggerState()
    }

    private func applyVoiceShortcut(to item: NSMenuItem) {
        let raw = UserDefaults.standard.string(forKey: "voiceTriggerKey") ?? "fn"
        guard let cfg = HotkeyConfig.parse(raw) else {
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
        personasMenu.removeAllItems()

        for persona in PersonaStore.shared.personas {
            let item = NSMenuItem(title: persona.name, action: #selector(selectPersona(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = persona.id
            item.state = persona.id == PersonaStore.shared.activePersonaId ? .on : .off
            if let raw = persona.hotkey, let cfg = HotkeyConfig.parse(raw) {
                let rep = cfg.menuRepresentation
                item.keyEquivalent = rep.key
                item.keyEquivalentModifierMask = rep.modifiers
            }
            personasMenu.addItem(item)
        }
    }

    @objc private func selectPersona(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PersonaStore.shared.setActive(id)
        rebuildPersonasMenu()
    }

    private func applySettingsShortcut(to item: NSMenuItem) {
        let raw = UserDefaults.standard.string(forKey: "settingsHotkey") ?? "cmd+shift+,"
        let cfg = HotkeyConfig.parse(raw) ?? HotkeyConfig(modifiers: [.maskCommand, .maskShift], keyCode: 0x2B)
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
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
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
        keyMonitor.stop()
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            KeyMic needs Accessibility permission to monitor the Fn key and apply key mappings.

            1. Open System Settings → Privacy & Security → Accessibility
            2. Add and enable KeyMic
            3. Restart the app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

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
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - HotkeyConfig → NSMenuItem

private extension HotkeyConfig {
    /// Convert this hotkey to an NSMenuItem keyEquivalent + modifier mask so the
    /// shortcut shows next to the menu item title (e.g. "⇧⌘,").
    var menuRepresentation: (key: String, modifiers: NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = []
        if modifiers.contains(.maskCommand)     { mods.insert(.command) }
        if modifiers.contains(.maskShift)       { mods.insert(.shift) }
        if modifiers.contains(.maskControl)     { mods.insert(.control) }
        if modifiers.contains(.maskAlternate)   { mods.insert(.option) }
        if modifiers.contains(.maskSecondaryFn) { mods.insert(.function) }

        let key: String
        switch keyCode {
        case 0x35: key = "\u{1B}"   // ⎋
        case 0x24: key = "\r"        // ↩
        case 0x33: key = "\u{8}"     // ⌫
        case 0x30: key = "\t"        // ⇥
        case 0x31: key = " "         // Space
        case 0x7B: key = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case 0x7C: key = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case 0x7D: key = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case 0x7E: key = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        default:
            if let token = HotkeyConfig.tokenToKeyCode.first(where: { $0.value == keyCode })?.key,
               token.count == 1 {
                key = token
            } else {
                key = ""
            }
        }
        return (key, mods)
    }
}

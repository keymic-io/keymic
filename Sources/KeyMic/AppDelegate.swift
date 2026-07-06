import AppKit
import CSherpaOnnx
import CoreML
import Speech
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let secureInputMonitor = SecureInputMonitor()
    /// Always non-nil after launch. Assigned the cheap Apple engine synchronously in
    /// `applicationDidFinishLaunching`, then (if SenseVoice is desired) upgraded asynchronously
    /// by `applySpeechEnginePreference()` once the model finishes loading off the main thread.
    private var speechEngine: (any SpeechEngineProtocol)!
    private let senseVoiceModelStore = SenseVoiceModelStore.shared
    /// The ONNX model store for the currently-selected engine. funasrNano and funasrMltNano are
    /// both `.onnx`-backed but live in separate stores/dirs; readiness + destDir track the active one.
    private var onnxModelStore: AssetStore {
        (UserDefaults.standard.string(forKey: Self.voiceModelKey) == "funasrMltNano")
            ? OnnxStores.mltModel : OnnxStores.model
    }
    /// Last-applied engine inputs, so `syncMenuStates()` only re-decides the engine when one of
    /// them changes (the change-detection guard avoids dispatching an off-main load on every
    /// defaults notification).
    private var lastVoiceModel: String?
    private var lastSenseVoiceLanguage: String?
    private var lastSenseVoiceModelReady: Bool?
    private var lastOnnxRuntimeReady: Bool?
    private var lastOnnxModelReady: Bool?
    private var lastSpeechLocaleCode: String = ""
    /// Bumped on every engine decision in `applySpeechEnginePreference()`. An async SenseVoice
    /// upgrade captures the generation at dispatch time and aborts its main-thread swap if a newer
    /// decision has superseded it — so a slow model load can never clobber a fresher choice.
    private var speechEngineGeneration = 0
#if KEYMIC_HAS_SPEECH_ANALYZER
    /// Backing store for `speechAnalyzerSupport`. Untyped because a stored property cannot carry
    /// `@available(macOS 26, *)`, and the concrete type is gated to macOS 26+.
    private var _speechAnalyzerSupport: AnyObject?
    @available(macOS 26, *)
    private var speechAnalyzerSupport: SpeechAnalyzerSupport {
        if let s = _speechAnalyzerSupport as? SpeechAnalyzerSupport { return s }
        let s = SpeechAnalyzerSupport()
        s.onReadinessChanged = { [weak self] in self?.applySpeechEnginePreference() }
        _speechAnalyzerSupport = s
        return s
    }
#endif
    private let textInjector = TextInjector()
    private lazy var actionRunner = HotkeyActionRunner(
        typeText: { [weak self] text in self?.textInjector.inject(text) }
    )
    private lazy var overlayPanel = OverlayPanel()
    private var clipboardController: ClipboardController!
    private var screenshotController: ScreenshotController?
    private var selectedTextEditorController: SelectedTextEditorController!

    private var singleInstanceLockURL: URL?
    private var personaObserverToken: NSObjectProtocol?

    /// Everything that, when changed, can invalidate KeyMonitor's in-flight
    /// input state (held trigger, repeat timers, modifier tracking). Cached so
    /// `syncMenuStates` only resets the input state machine when one of these
    /// actually changed — NOT on every `UserDefaults.didChangeNotification`
    /// (Sparkle's SULastCheckTime, screenshot prefs, any @AppStorage write…),
    /// which would interrupt an in-progress dictation session.
    private struct InputConfigSnapshot: Equatable {
        let hotkeys: HotkeySettingsSnapshot
        let keyMappings: [KeyMapping]
        let keyMappingEnabled: Bool

        static func current() -> InputConfigSnapshot {
            InputConfigSnapshot(
                hotkeys: HotkeySettingsStore.shared.snapshot,
                keyMappings: KeyMappingManager.shared.mappings,
                keyMappingEnabled: KeyMappingManager.shared.isEnabled
            )
        }
    }
    private var lastInputConfigSnapshot: InputConfigSnapshot?

    private var personaEngine: PersonaEngine!
    private var voiceTrigger: VoiceTrigger!
    private var speechSessionHost: DefaultSpeechSessionHost!
    private var llmClient: OpenAICompatibleLLMClient!

    /// Cached frontmost-app bundle ID. Updated via `NSWorkspace.didActivateApplicationNotification`.
    /// KeyMonitor's event-tap callback reads this O(1); calling
    /// `NSWorkspace.shared.frontmostApplication` directly in the callback can stall
    /// LaunchServices for hundreds of ms and trigger the 1s tap-disable timeout
    /// (which presents as system-wide kbd/mouse freezes).
    private var cachedFrontBundleID: String?

    private static let voiceEnabledKey = "voiceEnabled"
    private static let selectedLocaleCodeKey = "selectedLocaleCode"
    /// Single model picker (D2): "apple" | "senseVoice" | "funasrNano" | "funasrMltNano". Replaces the
    /// old `senseVoiceEnabled` toggle as the engine selector.
    private static let voiceModelKey = "voiceModel"
    private static let clipboardSchemaVersionKey = "clipboardSchemaVersion"
    private static let clipboardSchemaVersion = 2

    private var voiceEnabledMenuTitle: String { String(localized: "Voice Enabled") }
    private(set) var isVoiceEnabled: Bool =
        UserDefaults.standard.object(forKey: AppDelegate.voiceEnabledKey) as? Bool ?? true

    private var voiceEnabledMenuItem: NSMenuItem!
    private weak var voiceToggleView: ToggleMenuItemView?
    private var personasRootMenuItem: NSMenuItem!
    private var personasMenu: NSMenu?
    private var keyMappingMenuItem: NSMenuItem!
    private var clipboardMenuItem: NSMenuItem!
    private weak var clipboardToggleView: ToggleMenuItemView?
    private var shortcutsMenuItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!
    private lazy var settingsWindow = SwiftUISettingsWindow()
    var selectedLocaleCode: String {
        get { UserDefaults.standard.string(forKey: Self.selectedLocaleCodeKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.selectedLocaleCodeKey) }
    }

    /// Region-free language code of the current selection — the single source that drives both
    /// the Apple locale and the offline engines' recognition language. Empty selection → "auto".
    private var currentSpeechLanguageCode: String {
        SpeechLanguageCatalog.languageCode(of: selectedLocaleCode) ?? "auto"
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

        // Clear any stale HID-level mappings left by a previous crash/SIGKILL.
        // `applicationWillTerminate` calls reset() on clean quit, but force-quit
        // or crash leaves hidutil UserKeyMapping active.
        HIDRemapper.reset()
        // `KeyMappingManager`'s singleton was already initialized via `keyMonitor`'s
        // stored property (default arg `.shared`), so its init-time `apply` was enqueued
        // and ran *before* the reset above on HIDRemapper's shared serial queue — leaving
        // the (empty) reset as the last write. Reapply now so our mappings land *after*
        // the reset; otherwise Caps Lock→Ctrl silently does nothing until the user toggles
        // key mapping off/on.
        KeyMappingManager.shared.reapplyHIDMappings()

        AppScreen.refresh()

        setupMainMenu()
        setupStatusBar()
        // Always start on the cheap Apple engine (no model load → main-safe). If SenseVoice is
        // desired it is upgraded asynchronously below in `applySpeechEnginePreference()`, after the
        // session host + downstream controllers are wired up.
        speechEngine = makeAppleEngine()
        recordSpeechBaselineFromCurrent()
        setupSpeechCallbacks()

        AppleSpeechEngine.requestPermissions { [weak self] granted, errorMsg in
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

        keyMonitor.onAction = { [weak self] actions in self?.actionRunner.run(actions) }
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
        textInjector.onCapturePending = { [weak self] in
            self?.clipboardController.capturePendingChange()
        }
        SelectionTextProvider.onMarkIgnored = { [weak self] text in
            self?.clipboardController.markPasteboardWrite(text)
        }
        OutputRouter.shared = OutputRouter(
            inject: { [weak self] text in self?.textInjector.inject(text) },
            onMarkIgnored: { [weak self] text in
                self?.clipboardController.markPasteboardWrite(text)
            },
            confirmShellRun: { command in
                await ShellConfirmationSheet.present(command: command)
            })

        llmClient = OpenAICompatibleLLMClient()
        personaEngine = PersonaEngine(
            llmClient: llmClient,
            clipboardStore: clipboardController.store,
            outputRouter: OutputRouter.shared
        )
        speechSessionHost = DefaultSpeechSessionHost(engine: speechEngine)
        voiceTrigger = VoiceTrigger(
            engine: personaEngine,
            sessionHost: speechSessionHost,
            overlayPanel: overlayPanel,
            personaStore: PersonaStore.shared,
            textInjector: textInjector
        )
        keyMonitor.onTriggerDown = { [weak self] in
            guard let self, self.isVoiceEnabled else { return }
            self.updateStatusIcon(recording: true)
            Task { @MainActor in self.voiceTrigger.onTriggerDown() }
        }
        keyMonitor.onTriggerUp = { [weak self] in
            guard let self else { return }
            self.updateStatusIcon(recording: false)
            Task { @MainActor in self.voiceTrigger.onTriggerUp() }
        }
        keyMonitor.onTriggerInterrupted = { [weak self] in
            guard let self else { return }
            self.updateStatusIcon(recording: false)
            Task { @MainActor in self.voiceTrigger.onTriggerInterrupted() }
        }
        keyMonitor.onExtraneousKeyDuringVoice = { [weak self] in
            guard let self else { return }
            self.updateStatusIcon(recording: false)
            Task { @MainActor in self.voiceTrigger.onExtraneousKeyDuringVoice() }
        }
        keyMonitor.isVoiceActive = { [weak self] in self?.voiceTrigger?.isActive ?? false }
        keyMonitor.isVoiceEnabled = { [weak self] in self?.isVoiceEnabled ?? false }
        keyMonitor.onClipboardHotkey = { [weak self] in self?.clipboardController.toggle() }
        keyMonitor.onClipboardSwitcherStep = { [weak self] in self?.clipboardController.stepSwitcher() }
        keyMonitor.onClipboardSwitcherCommit = { [weak self] in self?.clipboardController.pasteSelectedItemsInOrder() }
        keyMonitor.onVaultHotkey = { [weak self] in
            self?.clipboardController.toggle(initialTab: .vault)
        }
        keyMonitor.onClipboardQuickPaste = { [weak self] index in self?.clipboardController.quickPaste(index: index) }
        keyMonitor.isClipboardPanelVisible = { [weak self] in self?.clipboardController.isPanelVisible == true }
        keyMonitor.onSettingsHotkey = { [weak self] in self?.openSettings() }
        screenshotController = ScreenshotController()
        keyMonitor.onScreenshotHotkey = { [weak self] in self?.screenshotController?.start() }
        selectedTextEditorController = SelectedTextEditorController(
            speechEngine: speechEngine,
            overlayPanel: overlayPanel
        )
        keyMonitor.onSelectedTextEditorHotkey = { [weak self] in
            self?.selectedTextEditorController.open()
        }
        // Now that the host + all engine consumers exist, decide the engine. If SenseVoice is
        // enabled this kicks off an off-main model load and swaps the engine in when ready;
        // otherwise it is a no-op (already on Apple).
        applySpeechEnginePreference()
        // Re-decide the engine whenever the model store's readiness changes outside a
        // UserDefaults edit — chiefly when a download finishes mid-session (so dictation
        // upgrades to SenseVoice without waiting for an unrelated preference change or a
        // restart), or when a load failure flips `.ready → .failed` (so we drop back to Apple).
        senseVoiceModelStore.addStateObserver { [weak self] _ in
            self?.syncSpeechEngineIfNeeded()
        }
        // Same auto-enable behavior for the ONNX runtime + Fun-ASR-Nano model stores: when a
        // download finishes mid-session (state → .ready) and that model is the picker selection,
        // re-deciding swaps dictation onto the ONNX engine without a restart (D2/4.3). A failure
        // (.ready → .failed) likewise drops back to Apple.
        ONNXRuntimeLoader.shared.store.addStateObserver { [weak self] _ in
            DispatchQueue.main.async { self?.syncSpeechEngineIfNeeded() }
        }
        OnnxStores.model.addStateObserver { [weak self] _ in
            DispatchQueue.main.async { self?.syncSpeechEngineIfNeeded() }
        }
        OnnxStores.mltModel.addStateObserver { [weak self] _ in
            DispatchQueue.main.async { self?.syncSpeechEngineIfNeeded() }
        }
        secureInputMonitor.onEnter = { [weak self] in self?.keyMonitor.onSecureInputEnter() }
        secureInputMonitor.onExit = { [weak self] in self?.keyMonitor.onSecureInputExit() }
        secureInputMonitor.start()
        clipboardController.start()
        _ = UpdaterController.shared

        HotkeySettingsStore.shared.ensureInitialized()
        lastInputConfigSnapshot = InputConfigSnapshot.current()

        TipsCatalog.clipboardPanelHotkeyDisplay = {
            HotkeySettingsStore.shared.hotkey(for: .clipboardPanel)?.displayString() ?? "⌥V"
        }

        // Register built-in hotkeys with HotkeyRegistry so persona recorder can detect conflicts.
        let registry = HotkeyRegistry.shared
        let hotkeys = HotkeySettingsStore.shared
        let builtIns: [(HotkeyFeature, HotkeyRegistry.Owner, String)] = [
            (.voiceTrigger, .voiceTrigger, "Voice trigger"),
            (.clipboardPanel, .clipboardPanel, "Clipboard panel"),
            (.vaultPanel, .vaultPanel, "Vault panel"),
            (.settingsWindow, .settingsWindow, "Settings window"),
            (.screenshot, .screenshot, "Screenshot"),
            (.selectedTextEditor, .selectedTextEditor, "Selected text editor"),
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
            selector: #selector(userDefaultsDidChange),
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
        // Only the primary instance (lock holder) owns the hidutil UserKeyMapping.
        // A second instance terminating itself in activateExistingInstanceIfNeeded()
        // must not reset, or it wipes the running primary's mapping.
        if let singleInstanceLockURL {
            HIDRemapper.reset()
            SingleInstance.releaseLock(at: singleInstanceLockURL)
        }
        if let token = personaObserverToken {
            NotificationCenter.default.removeObserver(token)
            personaObserverToken = nil
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

    // Voice pipeline lives in PersonaPlatform/Triggers/VoiceTrigger.

    // MARK: - Speech engine factory

    /// Build the Apple recognizer (the always-available fallback). Cheap — NO model load —
    /// so it is safe to call on the main thread. Seeds `selectedLocaleCode` on first launch
    /// (preserves the behavior of the old property initializer).
    private func makeAppleEngine() -> AppleSpeechEngine {
        let saved = selectedLocaleCode
        let code: String
        if !saved.isEmpty {
            code = saved
        } else {
            code = AppDelegate.defaultSpeechLocaleCode()
            selectedLocaleCode = code
        }
        logger.info("speech engine: Apple (locale=\(code, privacy: .public))")
        return AppleSpeechEngine(locale: Locale(identifier: code))
    }

    /// Build a `SenseVoiceSpeechEngine` from an ALREADY-LOADED `MLModel`. The heavy 432 MB disk
    /// load happens in the caller (off main); this only wires up the bundled am.mvn / vocab and
    /// is cheap enough for the main thread. Returns nil if the bundled resources are missing, in
    /// which case the caller stays on Apple.
    private func makeSenseVoiceEngineIfPossible(model: MLModel) -> (any SpeechEngineProtocol)? {
        guard let mvnURL = Bundle.main.url(forResource: "am", withExtension: "mvn"),
              let vocabURL = Bundle.main.url(
                forResource: "chn_jpn_yue_eng_ko_spectok.bpe", withExtension: "model") else {
            logger.warning("SenseVoice resources missing (am.mvn / SPM .model); staying on Apple")
            return nil
        }
        let langKey = currentSpeechLanguageCode
        let languageId = SenseVoiceConfig.languageIds[langKey] ?? 0
        logger.info("speech engine: SenseVoice (lang=\(langKey, privacy: .public))")
        return SenseVoiceSpeechEngine(
            model: SenseVoiceModel(model: model),
            fbank: FbankExtractor(mvnPath: mvnURL.path),
            decoder: CTCDecoder(
                vocab: SenseVoiceVocab(spmModelPath: vocabURL.path),
                blankId: SenseVoiceConfig.blankId),
            languageId: languageId,
            textnormId: SenseVoiceConfig.defaultTextNorm)
    }

    /// Central engine decision. Main-safe: when the factory wants Apple we swap synchronously;
    /// when it wants SenseVoice we load the model OFF the main thread and only build + swap the
    /// (`@MainActor`) engine back on main once it is loaded. The main thread is NEVER blocked on
    /// `loadModel()`. A generation counter discards a stale async upgrade if a newer decision
    /// has run in the meantime.
    private func applySpeechEnginePreference() {
        let sonomaOrEarlier: Bool = {
            if #available(macOS 15, *) { return false } else { return true }
        }()
        let model = UserDefaults.standard.string(forKey: AppDelegate.voiceModelKey) ?? "apple"
        let langKey = currentSpeechLanguageCode
        let svReady = senseVoiceModelStore.state == .ready
        let rtReady = ONNXRuntimeLoader.shared.store.state == .ready
        let onnxReady = onnxModelStore.state == .ready
        let isMacOS26OrLater: Bool = {
            if #available(macOS 26, *) { return true } else { return false }
        }()
        let speechLocale: Locale = {
            let code = selectedLocaleCode
            return code.isEmpty ? Locale.current : Locale(identifier: code)
        }()
        var localeSupported = false
        var assetReady = false
        var assetDownloading = false
#if KEYMIC_HAS_SPEECH_ANALYZER
        if #available(macOS 26, *) {
            speechAnalyzerSupport.bootstrapIfNeeded()
            localeSupported = speechAnalyzerSupport.isSupported(speechLocale)
            assetReady = speechAnalyzerSupport.isAssetReady(speechLocale)
            assetDownloading = speechAnalyzerSupport.isDownloading(speechLocale)
            // Supported but not installed → kick a download (no-op if already going/installed).
            if localeSupported && !assetReady { speechAnalyzerSupport.ensureAsset(for: speechLocale) }
        }
#endif
        let choice = SpeechEngineFactory.choose(
            model: model,
            osIsSonomaOrEarlier: sonomaOrEarlier,
            senseVoiceReady: svReady,
            onnxRuntimeReady: rtReady,
            onnxModelReady: onnxReady,
            isMacOS26OrLater: isMacOS26OrLater,
            localeSupportedBySpeechAnalyzer: localeSupported,
            speechAnalyzerAssetReady: assetReady)

        // Bump generation so a stale async upgrade can't clobber a newer decision.
        speechEngineGeneration &+= 1
        let gen = speechEngineGeneration

        if choice == .speechAnalyzer {
#if KEYMIC_HAS_SPEECH_ANALYZER
            if #available(macOS 26, *), let fmt = speechAnalyzerSupport.analyzerFormat {
                let engine = SpeechAnalyzerSpeechEngine(locale: speechLocale, analyzerFormat: fmt)
                speechEngine = engine
                setupSpeechCallbacks()
                speechSessionHost?.replaceEngine(engine)
                selectedTextEditorController?.replaceEngine(engine)
                recordSpeechBaseline(model: model, lang: langKey, svReady: svReady, rtReady: rtReady, onnxReady: onnxReady)
                SpeechEngineStatusStore.shared.update(.speechAnalyzer)
                return
            }
#endif
            // analyzerFormat not ready yet (or not compiled) → handled by the Apple branch below.
        }

        // Apple legacy path — also catches a .speechAnalyzer choice whose analyzer engine could
        // not be built (format not ready / define off), so it never falls into the SenseVoice
        // async-load block below (which has no `enabled` gate).
        if choice == .apple || choice == .speechAnalyzer {
            speechEngine = makeAppleEngine()
            setupSpeechCallbacks()
            speechSessionHost?.replaceEngine(speechEngine)
            selectedTextEditorController?.replaceEngine(speechEngine)
            recordSpeechBaseline(model: model, lang: langKey, svReady: svReady, rtReady: rtReady, onnxReady: onnxReady)
            SpeechEngineStatusStore.shared.update(
                assetDownloading ? .sfSpeechRecognizerDownloadingAnalyzerAsset : .sfSpeechRecognizer)
            return
        }

        if choice == .onnx {
            // ONNX Fun-ASR-Nano: dlopen runtime + build recognizer OFF main (0.6B LLM init is
            // heavy), then build + swap the (@MainActor) engine back on main. recognizer ownership
            // is handed to ONNXSpeechEngine (it destroys it in deinit). Any failure → fall back to
            // Apple. macOS 15+ only.
            guard #available(macOS 15, *) else { return }
            let m = onnxModelStore.destDir   // capture on main (main-actor property) before off-main work
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                guard ONNXRuntimeLoader.shared.loadIfReady() else {
                    DispatchQueue.main.async { self.fallbackToApple(gen: gen) }
                    return
                }
                var err = [CChar](repeating: 0, count: 1024)
                let rec = sherpa_create_funasr(
                    m.appendingPathComponent("encoder_adaptor.int8.onnx").path,
                    m.appendingPathComponent("llm.int8.onnx").path,
                    m.appendingPathComponent("embedding.int8.onnx").path,
                    m.appendingPathComponent("Qwen3-0.6B").path,
                    &err, Int32(err.count))
                DispatchQueue.main.async {
                    // A newer decision superseded us — drop this recognizer.
                    guard gen == self.speechEngineGeneration else {
                        if let rec { sherpa_destroy(rec) }
                        return
                    }
                    guard let rec else {
                        logger.error("create_funasr failed: \(String(cString: err), privacy: .public)")
                        self.fallbackToApple(gen: gen)
                        return
                    }
                    let engine = ONNXSpeechEngine(recognizer: rec, locale: self.speechEngine.locale)
                    self.speechEngine = engine
                    self.setupSpeechCallbacks()
                    self.speechSessionHost?.replaceEngine(engine)
                    self.selectedTextEditorController?.replaceEngine(engine)
                    self.recordSpeechBaseline(model: model, lang: langKey, svReady: svReady, rtReady: rtReady, onnxReady: onnxReady)
                    SpeechEngineStatusStore.shared.update(.onnx)
                }
            }
            return
        }

        // SenseVoice desired: load model OFF main, then build + swap ON main.
        guard #available(macOS 15, *) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let mlModel = self.senseVoiceModelStore.loadModel()  // heavy disk load, OFF main
            DispatchQueue.main.async {
                // A newer decision superseded us — drop this swap.
                guard gen == self.speechEngineGeneration else { return }
                guard let mlModel,
                      let engine = self.makeSenseVoiceEngineIfPossible(model: mlModel) else {
                    // Model failed to load (e.g. corrupt) or resources missing → stay on Apple.
                    return
                }
                self.speechEngine = engine
                self.setupSpeechCallbacks()
                self.speechSessionHost?.replaceEngine(engine)
                self.selectedTextEditorController?.replaceEngine(engine)
                self.recordSpeechBaseline(model: model, lang: langKey, svReady: true, rtReady: rtReady, onnxReady: onnxReady)
                SpeechEngineStatusStore.shared.update(.senseVoice)
            }
        }
    }

    /// Synchronously revert to the Apple engine (used when the ONNX path fails to load runtime or
    /// build the recognizer). No-op if a newer engine decision has already superseded `gen`.
    private func fallbackToApple(gen: Int) {
        guard gen == speechEngineGeneration else { return }
        speechEngine = makeAppleEngine()
        setupSpeechCallbacks()
        speechSessionHost?.replaceEngine(speechEngine)
        selectedTextEditorController?.replaceEngine(speechEngine)
        SpeechEngineStatusStore.shared.update(.sfSpeechRecognizer)
    }

    private func recordSpeechBaseline(model: String, lang: String, svReady: Bool, rtReady: Bool, onnxReady: Bool) {
        lastVoiceModel = model
        lastSenseVoiceLanguage = lang
        lastSenseVoiceModelReady = svReady
        lastOnnxRuntimeReady = rtReady
        lastOnnxModelReady = onnxReady
        // Also baseline the locale so a locale change re-decides the engine (SpeechAnalyzer
        // asset support is locale-specific).
        lastSpeechLocaleCode = selectedLocaleCode
    }

    /// Snapshot the inputs that determine engine selection, so the next `syncMenuStates()` only
    /// re-decides when one of them changes.
    private func recordSpeechBaselineFromCurrent() {
        recordSpeechBaseline(
            model: UserDefaults.standard.string(forKey: AppDelegate.voiceModelKey) ?? "apple",
            lang: currentSpeechLanguageCode,
            svReady: senseVoiceModelStore.state == .ready,
            rtReady: ONNXRuntimeLoader.shared.store.state == .ready,
            onnxReady: onnxModelStore.state == .ready)
    }

    /// Re-decide the speech engine iff a SenseVoice-relevant input changed (toggle, language,
    /// or model readiness) versus the last-applied baseline. Skips work otherwise so the
    /// high-frequency `syncMenuStates()` stays cheap and never dispatches an off-main load when
    /// nothing changed.
    private func syncSpeechEngineIfNeeded() {
        let model = UserDefaults.standard.string(forKey: AppDelegate.voiceModelKey) ?? "apple"
        let language = currentSpeechLanguageCode
        let svReady = senseVoiceModelStore.state == .ready
        let rtReady = ONNXRuntimeLoader.shared.store.state == .ready
        let onnxReady = onnxModelStore.state == .ready
        let localeCode = selectedLocaleCode
        if model == lastVoiceModel,
           language == lastSenseVoiceLanguage,
           svReady == lastSenseVoiceModelReady,
           rtReady == lastOnnxRuntimeReady,
           onnxReady == lastOnnxModelReady,
           localeCode == lastSpeechLocaleCode {
            return
        }
        applySpeechEnginePreference()
    }

    // MARK: - Speech callbacks

    private func setupSpeechCallbacks() {
        speechEngine.onPartialResult = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                self?.speechSessionHost?.routePartial(text)
            }
        }
        speechEngine.onFinalResult = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                self?.speechSessionHost?.routeFinal(text)
            }
        }
        speechEngine.onError = { [weak self] msg in
            DispatchQueue.main.async { [weak self] in
                self?.speechSessionHost?.routeError(msg)
            }
        }
        speechEngine.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async { [weak self] in
                self?.speechSessionHost?.routeAudioLevel(level)
            }
        }
        speechEngine.onLocaleUnavailable = { [weak self] msg in
            DispatchQueue.main.async { [weak self] in
                self?.showAlert(title: String(localized: "Language Unavailable"), message: msg)
            }
        }
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

        // Group 1: voice, persona
        voiceEnabledMenuItem = NSMenuItem(title: voiceEnabledMenuTitle, action: nil, keyEquivalent: "")
        let voiceView = ToggleMenuItemView(
            title: voiceEnabledMenuTitle,
            hotkeyText: HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)?.displayString(),
            icon: symbolImage("mic.fill"),
            isOn: { [weak self] in self?.isVoiceEnabled ?? false },
            onToggle: { [weak self] in self?.toggleVoiceEnabled() }
        )
        voiceEnabledMenuItem.view = voiceView
        // Keep `.state` pinned to `.on` so NSMenu always reserves a state column
        // and the non-toggle rows below keep a constant indentation. The actual
        // on/off status is drawn by the view, not the system checkmark.
        voiceEnabledMenuItem.state = .on
        voiceToggleView = voiceView
        menu.addItem(voiceEnabledMenuItem)

        personasRootMenuItem = NSMenuItem(title: String(localized: "Set Voice Persona"), action: nil, keyEquivalent: "")
        personasRootMenuItem.image = symbolImage("person.crop.circle.badge.checkmark")
        let personasMenu = NSMenu()
        personasRootMenuItem.submenu = personasMenu
        self.personasMenu = personasMenu
        rebuildPersonasMenu()
        menu.addItem(personasRootMenuItem)

        menu.addItem(.separator())

        // Group 2: key mapping, shortcuts, clipboard history
        keyMappingMenuItem = NSMenuItem(title: String(localized: "Key Mapping"), action: nil, keyEquivalent: "")
        keyMappingMenuItem.view = ToggleMenuItemView(
            title: String(localized: "Key Mapping"),
            hotkeyText: nil,
            icon: symbolImage("keyboard"),
            isOn: { KeyMappingManager.shared.isEnabled },
            onToggle: { [weak self] in self?.toggleKeyMapping() }
        )
        keyMappingMenuItem.state = .on
        menu.addItem(keyMappingMenuItem)

        shortcutsMenuItem = NSMenuItem(title: String(localized: "Shortcuts"), action: nil, keyEquivalent: "")
        shortcutsMenuItem.view = ToggleMenuItemView(
            title: String(localized: "Shortcuts"),
            hotkeyText: nil,
            icon: symbolImage("bolt.horizontal"),
            isOn: { HotkeyPreferences.enabled },
            onToggle: { [weak self] in self?.toggleShortcuts() }
        )
        shortcutsMenuItem.state = .on
        menu.addItem(shortcutsMenuItem)

        clipboardMenuItem = NSMenuItem(title: String(localized: "Clipboard History"), action: nil, keyEquivalent: "")
        let clipboardView = ToggleMenuItemView(
            title: String(localized: "Clipboard History"),
            hotkeyText: HotkeySettingsStore.shared.hotkey(for: .clipboardPanel)?.displayString(),
            icon: symbolImage("doc.on.clipboard"),
            isOn: { ClipboardPreferences.enabled },
            onToggle: { [weak self] in self?.toggleClipboard() }
        )
        clipboardMenuItem.view = clipboardView
        clipboardToggleView = clipboardView
        clipboardMenuItem.state = .on
        menu.addItem(clipboardMenuItem)

        menu.addItem(.separator())

        // Group 3: settings, updates, quit
        settingsMenuItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: "")
        settingsMenuItem.target = self
        settingsMenuItem.image = symbolImage("gearshape")
        applySettingsShortcut(to: settingsMenuItem)
        menu.addItem(settingsMenuItem)

        let checkUpdateItem = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdateItem.target = self
        checkUpdateItem.image = symbolImage("arrow.down.circle")
        menu.addItem(checkUpdateItem)

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
        voiceToggleView?.needsDisplay = true

        if !enabled {
            updateStatusIcon(recording: false)
            if let voiceTrigger {
                Task { @MainActor in voiceTrigger.onTriggerInterrupted() }
            }
        }
    }

    @objc private func toggleKeyMapping() {
        KeyMappingManager.shared.isEnabled.toggle()
    }

    @objc private func toggleClipboard() {
        let newValue = !ClipboardPreferences.enabled
        UserDefaults.standard.set(newValue, forKey: ClipboardPreferences.enabledKey)
    }

    @objc private func toggleShortcuts() {
        let newValue = !HotkeyPreferences.enabled
        UserDefaults.standard.set(newValue, forKey: HotkeyPreferences.enabledKey)
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        cachedFrontBundleID = app?.bundleIdentifier
    }

    @objc private func userDefaultsDidChange() {
        // UserDefaults.didChangeNotification is delivered synchronously on the
        // posting thread — which can be inside the event-tap callback (e.g. a
        // HotkeyRecorder commit writing hotkeySettings.v1) or a background
        // queue. Hop to the main queue so menu/NSMenu/KeyMonitor work never
        // runs in the tap callback path or off the main thread.
        DispatchQueue.main.async { [weak self] in self?.syncMenuStates() }
    }

    private func syncMenuStates() {
        // Mirror runtime state from UserDefaults whenever any preference changes
        // (SwiftUI Settings writes directly via @AppStorage). The toggle rows use
        // custom views that read live state at draw time, so they refresh on the
        // next menu open — no `.state` mirroring needed here (and `.state` stays
        // pinned to `.on` to keep the state column reserved).
        applySettingsShortcut(to: settingsMenuItem)

        let defaultsVoice = UserDefaults.standard.object(forKey: Self.voiceEnabledKey) as? Bool ?? true
        if defaultsVoice != isVoiceEnabled {
            setVoiceEnabled(defaultsVoice)
        }

        // Voice-model picker / language / store readiness reach us via
        // UserDefaults.didChangeNotification — same channel as the Apple locale below.
        // Only rebuild the engine when an engine- or locale-relevant input actually changed.
        syncSpeechEngineIfNeeded()

        // Apple locale only applies when the live engine is the Apple one; SenseVoice picks
        // its language at construction time (re-decided above), so skip it for SenseVoice.
        if let apple = speechEngine as? AppleSpeechEngine {
            let code = selectedLocaleCode
            let newLocale = code.isEmpty ? Locale.current : Locale(identifier: code)
            if apple.locale.identifier != newLocale.identifier {
                apple.locale = newLocale
            }
        }

        voiceToggleView?.updateHotkey(HotkeySettingsStore.shared.hotkey(for: .voiceTrigger)?.displayString())
        clipboardToggleView?.updateHotkey(HotkeySettingsStore.shared.hotkey(for: .clipboardPanel)?.displayString())
        rebuildPersonasMenu()

        // Reset input state only when hotkey / voice-trigger / key-mapping
        // configuration actually changed (it can invalidate held-trigger and
        // repeat-timer state). Unrelated defaults writes must not interrupt an
        // in-flight dictation session or clear live modifier tracking.
        let config = InputConfigSnapshot.current()
        if config != lastInputConfigSnapshot {
            lastInputConfigSnapshot = config
            keyMonitor.resetAllInputState(reason: .settingsReload)
        }
    }

    private func rebuildPersonasMenu() {
        guard let personasMenu else { return }
        let personas = PersonaStore.shared.personas

        // The root item shows the active persona's name, or the default label when none.
        personasRootMenuItem?.title = PersonaStore.shared.activePersona?.name
            ?? String(localized: "Set Voice Persona")

        // Fast path: if persona identity + title + hotkey are unchanged, just redraw
        // existing views (preserves NSMenu tracking state while the submenu is open).
        // Title and hotkey must be compared too: the views render immutable copies,
        // so a renamed persona or re-recorded hotkey needs a full rebuild.
        let existing = personasMenu.items.compactMap { $0.view as? PersonaMenuItemView }
        if existing.count == personas.count,
           zip(existing, personas).allSatisfy({ view, persona in
               view.personaId == persona.id
                   && view.title == persona.name
                   && view.hotkeyText == HotkeySettingsStore.shared
                       .personaHotkey(personaId: persona.id)?
                       .displayString()
           }) {
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

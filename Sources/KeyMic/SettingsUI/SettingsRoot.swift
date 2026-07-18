import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window host

final class SwiftUISettingsWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = String(localized: "KeyMic Settings")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        let host = NSHostingController(rootView: SettingsRootView())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentViewController = host
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "w"
        {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, account, voice, llm, personas, keyMapping, shortcuts, clipboard, screenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .account: String(localized: "Account")
        case .voice: String(localized: "Voice")
        case .llm: "LLM"
        case .personas: String(localized: "Personas")
        case .keyMapping: String(localized: "Key Mapping")
        case .shortcuts: String(localized: "Shortcuts")
        case .clipboard: String(localized: "Clipboard")
        case .screenshot: String(localized: "Screenshot")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "person.crop.circle"
        case .voice: "mic"
        case .llm: "sparkles"
        case .personas: "person.crop.circle.badge.checkmark"
        case .keyMapping: "keyboard"
        case .shortcuts: "command.square"
        case .clipboard: "doc.on.clipboard"
        case .screenshot: "camera.on.rectangle"
        }
    }
}

// MARK: - App language

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case system = ""
    case en = "en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja = "ja"
    case ko = "ko"
    case de = "de"
    case fr = "fr"
    case es = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System default")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        }
    }

    /// Dedicated KeyMic-only key so we never confuse the user's explicit choice
    /// with the macOS-level `AppleLanguages` global, which would leak through
    /// `UserDefaults.standard` when the app has no override of its own.
    private static let overrideKey = "appLanguageOverride"

    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey),
              !raw.isEmpty else {
            return .system
        }
        return AppLanguage(rawValue: raw) ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        if self == .system {
            defaults.removeObject(forKey: Self.overrideKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(rawValue, forKey: Self.overrideKey)
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}


// MARK: - Root

struct SettingsRootView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail
                .frame(minWidth: 480, idealWidth: 560, minHeight: 420)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .account: AccountSettingsView()
        case .voice: VoiceSettingsView()
        case .llm: LLMSettingsView()
        case .personas: PersonasView()
        case .clipboard: ClipboardSettingsView()
        case .keyMapping: KeyMappingSettingsSection()
        case .shortcuts: ShortcutsSettingsSection()
        case .screenshot: ScreenshotSettingsView()
        }
    }
}


private func hotkeyBinding(_ store: HotkeySettingsStore, for feature: HotkeyFeature) -> Binding<String> {
    Binding(
        get: { store.rawHotkey(for: feature) },
        set: { newValue in
            guard let config = HotkeyConfig.parse(newValue) else { return }
            do {
                try store.setHotkey(config, for: feature)
            } catch {
                NSLog("[Settings] Failed to save hotkey: \(error)")
            }
        }
    )
}

private func resetHotkey(_ store: HotkeySettingsStore, for feature: HotkeyFeature) -> String? {
    do {
        try store.resetHotkey(for: feature)
        return nil
    } catch let error as HotkeySettingsStore.ValidationError {
        return error.message
    } catch {
        return error.localizedDescription
    }
}

// MARK: - Screenshot

private struct ScreenshotSettingsView: View {
    @AppStorage("screenshotEnabled") private var screenshotEnabled: Bool = true
    @State private var hotkeyStore = HotkeySettingsStore.shared
    @State private var hotkeyResetError: String?

    private var screenshotHotkey: Binding<String> { hotkeyBinding(hotkeyStore, for: .screenshot) }

    private var hotkeyDisplayString: String {
        HotkeyConfig.parse(screenshotHotkey.wrappedValue)?.displayString() ?? "⌘⇧A"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable screenshot", isOn: $screenshotEnabled)
                LabeledContent("Hotkey:") {
                    HStack(spacing: 8) {
                        HotkeyRecorderField(
                            encoded: screenshotHotkey,
                            mode: .combo,
                            validator: { cfg in hotkeyStore.validationMessage(for: cfg, owner: .feature(.screenshot)) },
                            showsClearButton: false
                        )
                        .frame(width: 160, height: 24)
                        Button("Reset") {
                            hotkeyResetError = resetHotkey(hotkeyStore, for: .screenshot)
                        }
                        .controlSize(.small)
                    }
                }
                .disabled(!screenshotEnabled)
                if let hotkeyResetError {
                    Text(hotkeyResetError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Screenshot")
            } footer: {
                Text(
                    "Press \(hotkeyDisplayString) to capture a region of the screen and open it in the annotation editor."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("automaticallyUpdates") private var automaticallyUpdates: Bool = true
    @AppStorage("telemetryEnabled") private var telemetryEnabled: Bool = true
    @State private var hotkeyStore = HotkeySettingsStore.shared
    @State private var hotkeyResetError: String?
    private var settingsHotkey: Binding<String> { hotkeyBinding(hotkeyStore, for: .settingsWindow) }
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()
    @State private var appLanguage: AppLanguage = .current

    private let accessibilityTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                switch LaunchAtLogin.setEnabled(newValue) {
                case .success:
                    launchAtLogin = newValue
                    launchAtLoginError = nil
                case .failure(let err):
                    launchAtLoginError = err.localizedDescription
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Picker(selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    Text("Language")
                }
                .onChange(of: appLanguage) { _, newValue in
                    newValue.apply()
                    confirmRestart()
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Automatically check and install updates", isOn: $automaticallyUpdates)
            } header: {
                Text("Updates")
            }

            Section {
                Toggle("Share anonymous diagnostics & crash reports", isOn: $telemetryEnabled)
                    .onChange(of: telemetryEnabled) { _, newValue in
                        TelemetryService.shared.setEnabled(newValue)
                        // One shared toggle drives both tools; turning off closes Sentry too.
                        CrashReportingService.shared.setEnabled(newValue)
                    }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Anonymous — never includes transcripts, clipboard, keystrokes, or screen content.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Accessibility:") {
                    AccessibilityStatusView(
                        granted: accessibilityGranted,
                        onOpenSettings: openAccessibilitySettings
                    )
                }
            } header: {
                Text("Permissions")
            } footer: {
                Group {
                    Text(
                        "KeyMic needs Accessibility to monitor the trigger key, apply key mappings, and synthesize paste."
                    )
                        + Text("  ") + Text("Version \(Bundle.main.appVersion)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Text("Speech: SenseVoiceSmall (FunASR) — FunASR Model License")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Link("FunASR Model License", destination: URL(string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")!)
                    Link("CoreML conversion", destination: URL(string: "https://huggingface.co/FluidInference/sensevoice-small-coreml")!)
                }
                .font(.callout)
            } header: {
                Text("Acknowledgements")
            }
        }
        .formStyle(.grouped)
        .onReceive(accessibilityTimer) { _ in
            let now = AXIsProcessTrusted()
            if now != accessibilityGranted { accessibilityGranted = now }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func confirmRestart() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Required")
        alert.informativeText = String(localized: "Restart KeyMic to apply the language change.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundlePath
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "sleep 1; open \"$1\"", "sh", path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }
}

private struct AccessibilityStatusView: View {
    let granted: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
                .imageScale(.medium)
            Text(granted ? "Granted" : "Not granted")
                .foregroundStyle(granted ? .primary : .secondary)
            if !granted {
                Button("Grant Access…", action: onOpenSettings)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(granted ? "Accessibility permission granted" : "Accessibility permission not granted")
        .accessibilityAddTraits(granted ? .isStaticText : [])
        .animation(.easeInOut(duration: 0.25), value: granted)
    }
}

extension Bundle {
    fileprivate var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - Voice

/// Drives the SenseVoice model download button + status text. Wraps the shared
/// `SenseVoiceModelStore` (which already hops its callback to main) and publishes its state
/// so SwiftUI redraws. The store is the single source of truth; AppDelegate's engine factory
/// reads the same `SenseVoiceModelStore.shared.state`.
@MainActor
final class SenseVoiceDownloadController: ObservableObject {
    @Published var state: SenseVoiceModelStore.State

    init() {
        state = SenseVoiceModelStore.shared.state
        // Mirror EVERY store transition, not just the ones from our own `download()` call —
        // so a load failure elsewhere (`.ready → .failed`) re-enables the download button, and
        // a download started from another path still updates this UI.
        SenseVoiceModelStore.shared.addStateObserver { [weak self] newState in
            self?.state = newState  // observer always fires on the main thread
        }
    }

    func download() {
        SenseVoiceModelStore.shared.ensureDownloaded { [weak self] newState in
            DispatchQueue.main.async { self?.state = newState }
        }
    }
}

/// Drives the ONNX runtime + Fun-ASR-Nano model download button/status. Wraps the two shared
/// stores (`ONNXRuntimeLoader.shared.store` + `OnnxStores.model`) — the same instances AppDelegate's
/// engine decision reads — and composes their two states into one user-facing `combined` state.
@MainActor
final class OnnxDownloadController: ObservableObject {
    @Published var runtimeState: AssetStore.State
    @Published var modelState: AssetStore.State
    private let modelStore: AssetStore

    init(modelStore: AssetStore) {
        self.modelStore = modelStore
        self.runtimeState = ONNXRuntimeLoader.shared.store.state
        self.modelState = modelStore.state
        // AssetStore hops its observer callback to main, so direct assignment is main-safe.
        ONNXRuntimeLoader.shared.store.addStateObserver { [weak self] s in self?.runtimeState = s }
        modelStore.addStateObserver { [weak self] s in self?.modelState = s }
    }

    /// Download runtime + model (both required). Runtime first; on ready, kick off the model.
    func download() {
        let runtime = ONNXRuntimeLoader.shared.store
        if runtime.state == .ready {
            modelStore.ensureDownloaded { _ in }
        } else {
            runtime.ensureDownloaded { [weak self] st in
                if case .ready = st { self?.modelStore.ensureDownloaded { _ in } }
            }
        }
    }

    /// Composite user-visible state: either failed → failed; both ready → ready; runtime download
    /// maps to 0–10%, model download to 10–100%.
    var combined: AssetStore.State {
        func frac(_ s: AssetStore.State) -> Double {
            if case .downloading(let f) = s { return f }
            if case .ready = s { return 1 }
            return 0
        }
        if case .failed(let m) = runtimeState { return .failed("runtime: \(m)") }
        if case .failed(let m) = modelState { return .failed("model: \(m)") }
        if runtimeState == .ready, modelState == .ready { return .ready }
        if case .downloading = runtimeState { return .downloading(frac(runtimeState) * 0.1) }
        if case .downloading = modelState { return .downloading(0.1 + frac(modelState) * 0.9) }
        return .notDownloaded
    }
}

private struct VoiceSettingsView: View {
    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @AppStorage("selectedLocaleCode") private var localeCode: String = ""
    // Single model picker (D2) replaces the old `senseVoiceEnabled` toggle.
    @AppStorage("voiceModel") private var voiceModel: String = "apple"
    @StateObject private var download = SenseVoiceDownloadController()
    @StateObject private var onnx = OnnxDownloadController(modelStore: OnnxStores.model)
    @StateObject private var onnxMlt = OnnxDownloadController(modelStore: OnnxStores.mltModel)
    @State private var hotkeyStore = HotkeySettingsStore.shared
    @State private var hotkeyResetError: String?
    private var triggerKey: Binding<String> { hotkeyBinding(hotkeyStore, for: .voiceTrigger) }

    private static let senseVoiceSupported: Bool = {
        if #available(macOS 15, *) { return true } else { return false }
    }()

    /// Unified status line for every downloadable model — identical wording across engines.
    /// In the stable states (not-downloaded / ready) the size is shown inline, so there is no
    /// separate "Size:" row.
    private func modelStatusText(_ phase: DownloadPhase, sizeText: String?) -> String {
        switch phase {
        case .notDownloaded:
            if let sizeText { return String(format: String(localized: "Not downloaded (%@)"), sizeText) }
            return String(localized: "Not downloaded")
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded())
            // Explicit `%lld%%` key (vs. interpolation) so the catalog lookup is deterministic.
            return String(format: String(localized: "Downloading… %lld%%"), percent)
        case .ready:
            if let sizeText { return String(format: String(localized: "Ready (%@)"), sizeText) }
            return String(localized: "Ready")
        case .failed(let msg):
            return String(format: String(localized: "Failed: %@"), msg)
        }
    }

    /// The byte-progress fraction while downloading, else nil.
    private var senseVoiceDownloadFraction: Double? {
        if case .downloading(let fraction) = download.state { return fraction }
        return nil
    }

    private var senseVoiceDownloadDisabled: Bool {
        switch download.state {
        case .ready, .downloading: return true
        case .notDownloaded, .failed: return false
        }
    }

    /// Reusable detail row for an ONNX engine, parameterized by its download controller + store.
    @ViewBuilder
    private func onnxModelRow(_ controller: OnnxDownloadController, store: AssetStore) -> some View {
        let fraction: Double? = {
            if case .downloading(let f) = controller.combined { return f }
            return nil
        }()
        let busy: Bool = {
            switch controller.combined {
            case .ready, .downloading: return true
            case .notDownloaded, .failed: return false
            }
        }()
        ModelDownloadRow(
            statusText: modelStatusText(DownloadPhase(controller.combined), sizeText: selectedModel?.sizeText),
            fraction: fraction,
            isReady: controller.combined == .ready,
            downloadTitle: "Download runtime + model",
            downloadDisabled: !Self.senseVoiceSupported || busy,
            folderURL: store.destDir,
            onDownload: { controller.download() }
        )
    }

    /// Distinct, region-free languages (deduped by language code). Stable across redraws.
    private static let languages: [SpeechLanguage] = SpeechLanguageCatalog.distinctLanguages()

    /// Selected language CODE (region-free). Persists into the full-locale `selectedLocaleCode`
    /// via a representative locale, so the Apple engine still gets a concrete locale.
    private var selectedLanguage: Binding<String> {
        Binding(
            get: {
                SpeechLanguageCatalog.languageCode(of: localeCode)
                    ?? Locale.current.language.languageCode?.identifier
                    ?? "en"
            },
            set: { code in
                if let locale = SpeechLanguageCatalog.representativeLocale(for: code) {
                    localeCode = locale.identifier
                }
            }
        )
    }

    private var selectedModel: VoiceModelOption? {
        VoiceModelCatalog.selectableModels.first { $0.id == voiceModel }
    }

    /// A model row's picker label: the model name, plus a static "[Preferred language not
    /// supported]" suffix when the model is available but can't recognize the selected language.
    /// Names stay verbatim (brand); the suffix is localized.
    private func modelPickerLabel(_ model: VoiceModelOption) -> String {
        let lang = selectedLanguage.wrappedValue
        if model.available, !model.supports(lang) {
            return model.displayName + "  " + String(localized: "[Preferred language not supported]")
        }
        return model.displayName
    }

    /// Whether a model row is disabled: the "coming soon" unavailable entries, and any available
    /// model that does not support the selected language (shown greyed rather than hidden).
    private func modelRowDisabled(_ model: VoiceModelOption) -> Bool {
        !model.available || !model.supports(selectedLanguage.wrappedValue)
    }

    /// When the language changes such that the live model no longer supports it, fall back to
    /// Apple (which supports every language the picker can show) so the active selection stays
    /// valid. The unsupported model still appears in the list, greyed out.
    private func resetModelIfUnsupported() {
        let lang = selectedLanguage.wrappedValue
        if let m = selectedModel, m.id != "apple", m.available, !m.supports(lang) {
            voiceModel = "apple"
        }
    }

    /// Uniform detail row under the model picker. Downloadable engines share `ModelDownloadRow`
    /// (status-with-inline-size / download-or-reveal); Apple is the built-in exception.
    @ViewBuilder
    private var modelDetailRows: some View {
        switch voiceModel {
        case "senseVoice":
            ModelDownloadRow(
                statusText: modelStatusText(DownloadPhase(download.state), sizeText: selectedModel?.sizeText),
                fraction: senseVoiceDownloadFraction,
                isReady: download.state == .ready,
                downloadTitle: "Download model",
                downloadDisabled: !Self.senseVoiceSupported || senseVoiceDownloadDisabled,
                folderURL: SenseVoiceModelStore.shared.modelURL,
                onDownload: { download.download() }
            )
        case "funasrNano":
            onnxModelRow(onnx, store: OnnxStores.model)
        case "funasrMltNano":
            onnxModelRow(onnxMlt, store: OnnxStores.mltModel)
        default:  // "apple" + unavailable models: no download, no on-disk folder.
            LabeledContent("Download:") {
                Text("Built into macOS — no download required")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable voice input", isOn: $voiceEnabled)

                Picker("Preferred Language:", selection: selectedLanguage) {
                    ForEach(Self.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .onChange(of: localeCode) { resetModelIfUnsupported() }

                LabeledContent("Trigger Key:") {
                    HotkeyRecorderWithClear(
                        encoded: triggerKey,
                        defaultEncoded: HotkeyFeature.defaults[HotkeyFeature.voiceTrigger.rawValue]!,
                        mode: .pureModifier,
                        validator: { cfg in hotkeyStore.validationMessage(for: cfg, owner: .feature(.voiceTrigger)) },
                        recorderWidth: 220,
                        resetAction: { hotkeyResetError = resetHotkey(hotkeyStore, for: .voiceTrigger) }
                    )
                }
                if let hotkeyResetError {
                    Text(hotkeyResetError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Hold the trigger key to dictate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Model:", selection: $voiceModel) {
                    ForEach(VoiceModelCatalog.selectableModels, id: \.id) { model in
                        Text(modelPickerLabel(model)).tag(model.id).disabled(modelRowDisabled(model))
                    }
                }
                .disabled(!Self.senseVoiceSupported)
                // SwiftUI's per-row `.disabled` greys the option but does NOT reliably block
                // selecting it in a pop-up Picker. Enforce it: any pick of a model that can't do
                // the current language bounces straight back to Apple. `onAppear` also heals a
                // selection that became unsupported via an earlier language change.
                .onChange(of: voiceModel) { resetModelIfUnsupported() }
                .onAppear { resetModelIfUnsupported() }

                modelDetailRows
            } header: {
                Text("Speech model")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !Self.senseVoiceSupported {
                        Text("Requires macOS 15+ for the local engines.")
                    }
                    Text(
                        "Local models run entirely on-device — no network after download. KeyMic falls back to Apple speech recognition when the selected model is unavailable or not yet downloaded."
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Engine-agnostic download phase. `SenseVoiceModelStore.State` and `AssetStore.State` are
/// structurally identical; normalizing into this lets one status formatter serve both.
private enum DownloadPhase {
    case notDownloaded, downloading(Double), ready, failed(String)

    init(_ s: SenseVoiceModelStore.State) {
        switch s {
        case .notDownloaded: self = .notDownloaded
        case .downloading(let f): self = .downloading(f)
        case .ready: self = .ready
        case .failed(let m): self = .failed(m)
        }
    }

    init(_ s: AssetStore.State) {
        switch s {
        case .notDownloaded: self = .notDownloaded
        case .downloading(let f): self = .downloading(f)
        case .ready: self = .ready
        case .failed(let m): self = .failed(m)
        }
    }
}

/// 统一的「模型下载/状态」展示行,所有可下载语音模型共用:状态文案(已就绪时含体积)+ 进度条 +
/// (未就绪)下载按钮 /(已就绪)在 Finder 显示。
private struct ModelDownloadRow: View {
    let statusText: String
    let fraction: Double?
    let isReady: Bool
    let downloadTitle: LocalizedStringKey
    let downloadDisabled: Bool
    let folderURL: URL?
    let onDownload: () -> Void

    var body: some View {
        LabeledContent("Download:") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isReady {
                        if let folderURL {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                            }
                        }
                    } else {
                        Button(downloadTitle, action: onDownload)
                            .disabled(downloadDisabled)
                    }
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
            }
        }
    }
}

// MARK: - LLM

private struct LLMSettingsView: View {
    @AppStorage("llmAPIBaseURL") private var apiBaseURL: String = "https://api.openai.com/v1"
    // TODO: migrate API key from UserDefaults to Keychain for security
    @AppStorage("llmAPIKey") private var apiKey: String = ""
    @AppStorage("llmModel") private var model: String = "gpt-4o-mini"

    @State private var status: TestStatus = .idle

    private enum TestStatus {
        case idle
        case testing
        case ok(String)
        case fail(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .testing: return String(localized: "Testing…")
            case .ok(let m): return String(localized: "OK: \(m)")
            case .fail(let m): return m
            }
        }

        var color: Color {
            switch self {
            case .idle, .testing: return .secondary
            case .ok: return .green
            case .fail: return .red
            }
        }
    }

    var body: some View {
        Form {
            Section {
                llmFieldRow("API Base URL") {
                    TextField("", text: $apiBaseURL, prompt: Text("https://api.openai.com/v1"))
                }

                llmFieldRow("API Key") {
                    SecureField("", text: $apiKey, prompt: Text("sk-…"))
                }

                llmFieldRow("Model") {
                    TextField("", text: $model, prompt: Text("gpt-4o-mini"))
                }
            }

            Section {
                HStack {
                    Text(status.text)
                        .foregroundStyle(status.color)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Test", action: runTest)
                        .disabled(apiKey.isEmpty || isBusy)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func llmFieldRow<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            (Text(label) + Text(verbatim: ":"))
                .fontWeight(.semibold)
                .frame(width: 160, alignment: .leading)

            content()
                .textFieldStyle(.plain)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    private var isBusy: Bool {
        if case .testing = status { return true }
        return false
    }

    private func runTest() {
        let client = OpenAICompatibleLLMClient()
        guard client.isReady else {
            status = .fail("API key is empty")
            return
        }
        status = .testing
        Task {
            do {
                let text = try await client.complete(
                    systemPrompt: "Return the input exactly as-is.",
                    userText: "Hello, this is a test.",
                    temperature: 0.0
                )
                await MainActor.run { status = .ok(text) }
            } catch {
                await MainActor.run { status = .fail(error.localizedDescription) }
            }
        }
    }
}

// MARK: - Clipboard

private struct ClipboardSettingsView: View {
    @AppStorage(ClipboardPreferences.enabledKey) private var enabled: Bool = true
    @AppStorage(ClipboardPreferences.ignoreConfidentialKey) private var ignoreConfidential: Bool = true
    @AppStorage(ClipboardPreferences.maxHistoryKey) private var maxHistory: Int = ClipboardPreferences.defaultMaxHistory
    @AppStorage(ClipboardPreferences.cleanupModeKey) private var cleanupModeRaw: String = CleanupMode.count.rawValue
    @AppStorage(ClipboardPreferences.cleanupDaysKey) private var cleanupDays: Int = ClipboardPreferences.defaultCleanupDays
    @AppStorage(ClipboardPreferences.panelPositionKey) private var panelPositionRaw: String = ClipboardPreferences.defaultPanelPosition.rawValue
    @State private var hotkeyStore = HotkeySettingsStore.shared
    @State private var hotkeyResetError: String?
    private var hotkey: Binding<String> { hotkeyBinding(hotkeyStore, for: .clipboardPanel) }
    private var vaultHotkey: Binding<String> { hotkeyBinding(hotkeyStore, for: .vaultPanel) }

    private var cleanupMode: Binding<CleanupMode> {
        Binding(
            get: { CleanupMode(rawValue: cleanupModeRaw) ?? .count },
            set: { cleanupModeRaw = $0.rawValue }
        )
    }

    private var panelPosition: Binding<ClipboardPanelPosition> {
        Binding(
            get: { ClipboardPanelPosition(rawValue: panelPositionRaw) ?? ClipboardPreferences.defaultPanelPosition },
            set: { panelPositionRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable clipboard history", isOn: $enabled)
                Toggle("Ignore confidential clipboards", isOn: $ignoreConfidential)
                    .disabled(!enabled)
            }

            Section {
                LabeledContent("Open panel:") {
                    HotkeyRecorderWithClear(
                        encoded: hotkey,
                        defaultEncoded: HotkeyFeature.defaults[HotkeyFeature.clipboardPanel.rawValue]!,
                        mode: .combo,
                        validator: { cfg in hotkeyStore.validationMessage(for: cfg, owner: .feature(.clipboardPanel)) },
                        recorderWidth: 160,
                        resetAction: { hotkeyResetError = resetHotkey(hotkeyStore, for: .clipboardPanel) }
                    )
                }
                LabeledContent("Open Vault:") {
                    HotkeyRecorderWithClear(
                        encoded: vaultHotkey,
                        defaultEncoded: HotkeyFeature.defaults[HotkeyFeature.vaultPanel.rawValue]!,
                        mode: .combo,
                        validator: { cfg in hotkeyStore.validationMessage(for: cfg, owner: .feature(.vaultPanel)) },
                        recorderWidth: 160,
                        resetAction: { hotkeyResetError = resetHotkey(hotkeyStore, for: .vaultPanel) }
                    )
                }
                if let hotkeyResetError {
                    Text(hotkeyResetError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Hotkeys")
            }
            .disabled(!enabled)

            Section {
                Picker("Panel position:", selection: panelPosition) {
                    Text("Follow cursor").tag(ClipboardPanelPosition.followCursor)
                    Text("Screen center").tag(ClipboardPanelPosition.screenCenter)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }
            .disabled(!enabled)

            Section {
                Picker("Limit by", selection: cleanupMode) {
                    Text("Count").tag(CleanupMode.count)
                    Text("Age").tag(CleanupMode.days)
                }
                .pickerStyle(.segmented)

                if cleanupMode.wrappedValue == .count {
                    Picker("History size:", selection: $maxHistory) {
                        ForEach(ClipboardPreferences.allowedHistorySizes, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                } else {
                    Picker("Keep for:", selection: $cleanupDays) {
                        ForEach(ClipboardPreferences.allowedCleanupDays, id: \.self) { d in
                            Text("\(d) days").tag(d)
                        }
                    }
                }
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Stores text clipboards only. Password-manager clipboards are ignored by default.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }

}

// MARK: - HotkeyRecorder bridge

struct HotkeyRecorderField: View {
    typealias DisplayName = (HotkeyConfig) -> String

    @Binding var config: HotkeyConfig?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let displayName: DisplayName?
    let showsClearButton: Bool

    init(
        config: Binding<HotkeyConfig?>,
        mode: HotkeyRecorder.Mode,
        validator: @escaping HotkeyRecorder.Validator,
        displayName: DisplayName? = nil,
        showsClearButton: Bool = true
    ) {
        self._config = config
        self.mode = mode
        self.validator = validator
        self.displayName = displayName
        self.showsClearButton = showsClearButton
    }

    init(encoded: Binding<String>, mode: HotkeyRecorder.Mode, validator: @escaping HotkeyRecorder.Validator, showsClearButton: Bool) {
        self._config = Binding(
            get: { HotkeyConfig.parse(encoded.wrappedValue) },
            set: { encoded.wrappedValue = $0?.encode() ?? "" }
        )
        self.mode = mode
        self.validator = validator
        self.displayName = nil
        self.showsClearButton = showsClearButton
    }

    var body: some View {
        HStack(spacing: 4) {
            HotkeyRecorderButton(
                config: $config,
                mode: mode,
                validator: validator,
                displayName: displayName
            )
            if showsClearButton && config != nil {
                Button {
                    config = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
    }
}

private struct HotkeyRecorderButton: NSViewRepresentable {
    @Binding var config: HotkeyConfig?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let displayName: HotkeyRecorderField.DisplayName?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> HotkeyRecorder {
        let coord = context.coordinator
        coord.lastConfig = config
        let recorder = HotkeyRecorder(
            initial: config,
            mode: mode,
            validator: validator
        ) { cfg in
            coord.lastConfig = cfg
            DispatchQueue.main.async {
                coord.parent.config = cfg
                coord.refreshTitle()
            }
        }
        coord.recorder = recorder
        coord.refreshTitle()
        return recorder
    }

    func updateNSView(_ nsView: HotkeyRecorder, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recorder = nsView
        guard config != context.coordinator.lastConfig else {
            context.coordinator.refreshTitle()
            return
        }
        context.coordinator.lastConfig = config
        nsView.updateValue(config)
        context.coordinator.refreshTitle()
    }

    final class Coordinator {
        var parent: HotkeyRecorderButton
        weak var recorder: HotkeyRecorder?
        var lastConfig: HotkeyConfig?
        init(parent: HotkeyRecorderButton) { self.parent = parent }

        func refreshTitle() {
            guard let recorder, let name = parent.displayName, let cfg = parent.config else { return }
            recorder.title = name(cfg)
        }
    }
}

// MARK: - HotkeyRecorder with clear / restore-default button

/// Recorder bound to an encoded string, with caller-defined reset behavior.
struct HotkeyRecorderWithClear: View {
    @Binding var encoded: String
    let defaultEncoded: String?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let recorderWidth: CGFloat
    let resetAction: () -> Void

    private var canReset: Bool {
        guard let def = defaultEncoded, let cfg = HotkeyConfig.parse(def) else {
            return encoded != ""
        }
        guard let cur = HotkeyConfig.parse(encoded) else { return true }
        return cur != cfg
    }

    var body: some View {
        HStack(spacing: 4) {
            HotkeyRecorderField(
                encoded: $encoded,
                mode: mode,
                validator: validator,
                showsClearButton: false
            )
                .frame(width: recorderWidth, height: 24)

            ClearHotkeyButton(
                hasDefault: defaultEncoded != nil,
                isEnabled: canReset,
                action: resetAction
            )
        }
    }
}

/// Recorder bound to a `HotkeyConfig?`, with a trailing "×" button that
/// restores the default (or clears the value, when no default is provided).
struct HotkeyRecorderConfigWithClear: View {
    @Binding var config: HotkeyConfig?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let displayName: HotkeyRecorderField.DisplayName?
    let recorderWidth: CGFloat

    init(
        config: Binding<HotkeyConfig?>,
        mode: HotkeyRecorder.Mode,
        validator: @escaping HotkeyRecorder.Validator,
        displayName: HotkeyRecorderField.DisplayName? = nil,
        recorderWidth: CGFloat
    ) {
        self._config = config
        self.mode = mode
        self.validator = validator
        self.displayName = displayName
        self.recorderWidth = recorderWidth
    }

    var body: some View {
        HotkeyRecorderField(
            config: $config,
            mode: mode,
            validator: validator,
            displayName: displayName
        )
        .frame(width: recorderWidth, height: 24)
    }
}

/// Compact "×" button used by encoded-string recorder wrappers that suppress
/// the field's built-in clear (e.g. to substitute a "restore default" action).
private struct ClearHotkeyButton: View {
    let hasDefault: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(isEnabled ? 1 : 0)
        .disabled(!isEnabled)
        .accessibilityLabel(hasDefault ? "Restore default hotkey" : "Clear hotkey")
        .help(hasDefault ? "Restore default" : "Clear")
    }
}

// MARK: - Key Mapping

private struct KeyMappingSettingsSection: View {
    @Bindable private var manager = KeyMappingManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable key mapping", isOn: $manager.isEnabled)
            } footer: {
                Text("Single-key remap. Add a mapping, press the desired key. Esc / Return / Delete exit recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                if manager.mappings.isEmpty {
                    Text("No mappings yet — click Add Mapping to create one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach($manager.mappings) { $mapping in
                        KeyMappingRow(mapping: $mapping) {
                            manager.mappings.removeAll { $0.id == mapping.id }
                        }
                    }
                }
            } header: {
                HStack(spacing: 0) {
                    Text("From").frame(width: 150, alignment: .leading)
                    Color.clear.frame(width: 24)
                    Text("To").frame(width: 150, alignment: .leading)
                    Spacer()
                    Text("On").frame(width: 40, alignment: .center)
                    Color.clear.frame(width: 28)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
            }
            .disabled(!manager.isEnabled)

            Section {
                Button {
                    manager.mappings.append(KeyMapping(enabled: false))
                } label: {
                    Label("Add Mapping", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .disabled(!manager.isEnabled)
        }
        .formStyle(.grouped)
    }
}

private struct KeyMappingRow: View {
    @Binding var mapping: KeyMapping
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                HotkeyRecorderConfigWithClear(
                    config: keyCodeBinding(for: \.fromKeyCode),
                    mode: .singleKey,
                    validator: validateFrom,
                    displayName: { KeyMapping.displayName(for: $0.keyCode) },
                    recorderWidth: 130
                )
                .frame(width: 150)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                HotkeyRecorderConfigWithClear(
                    config: keyCodeBinding(for: \.toKeyCode),
                    mode: .singleKey,
                    validator: validateTo,
                    displayName: { KeyMapping.displayName(for: $0.keyCode) },
                    recorderWidth: 130
                )
                .frame(width: 150)

                Spacer(minLength: 8)

                Toggle("", isOn: $mapping.enabled)
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 40, alignment: .center)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 28, alignment: .center)
            }

            if let warning = registryWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Non-blocking: remapping a source key silently disables every hotkey built on
    /// that key (remap runs first in KeyMonitor). Warn, but allow deliberate overrides.
    private var registryWarning: String? {
        guard mapping.enabled, let from = mapping.fromKeyCode else { return nil }
        let hits = HotkeyRegistry.shared.entriesUsing(
            keyCode: from, excluding: .keyMapping(id: mapping.id.uuidString)
        ).filter { if case .keyMapping = $0.owner { return false } else { return true } }
        return hits.first.map { "Remapping this key disables: \($0.purpose)" }
    }

    private func keyCodeBinding(for keyPath: WritableKeyPath<KeyMapping, CGKeyCode?>) -> Binding<HotkeyConfig?> {
        Binding(
            get: {
                guard let kc = mapping[keyPath: keyPath] else { return nil }
                return HotkeyConfig(modifiers: [], keyCode: kc)
            },
            set: { mapping[keyPath: keyPath] = $0?.keyCode }
        )
    }

    private func validateFrom(_ cfg: HotkeyConfig) -> String? {
        if mapping.toKeyCode == cfg.keyCode { return "Source and target must differ" }
        let others = KeyMappingManager.shared.mappings.filter { $0.id != mapping.id }
        if others.contains(where: { $0.fromKeyCode == cfg.keyCode }) {
            return "\(KeyMapping.displayName(for: cfg.keyCode)) is already mapped"
        }
        return nil
    }

    private func validateTo(_ cfg: HotkeyConfig) -> String? {
        if mapping.fromKeyCode == cfg.keyCode { return "Source and target must differ" }
        return nil
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsSection: View {
    @Bindable private var store = HotkeyBindingsStore.shared
    @State private var editing: EditingState?

    private struct EditingState: Identifiable {
        let id: UUID
        var binding: HotkeyBinding
        var isNew: Bool
    }

    var body: some View {
        Form {
            Section {
                if store.bindings.isEmpty {
                    Text("No shortcuts yet — click Add Shortcut to create one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach($store.bindings) { $binding in
                        ShortcutRow(
                            binding: $binding,
                            onEdit: {
                                editing = EditingState(id: binding.id, binding: binding, isNew: false)
                            },
                            onDelete: {
                                store.bindings.removeAll { $0.id == binding.id }
                            }
                        )
                    }
                }
            } header: {
                Text(
                    "Trigger any text input, key press, or shell script with a hotkey combo. Shell actions run with your full user privileges — only add shortcuts you trust."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Button {
                    let new = HotkeyBinding(trigger: "", actions: [.typeText("")], enabled: true)
                    editing = EditingState(id: new.id, binding: new, isNew: true)
                } label: {
                    Label("Add Shortcut", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { state in
            BindingEditorSheet(
                original: state.binding,
                isNew: state.isNew,
                validator: { cfg in validate(cfg, excluding: state.id) },
                onSave: { saved in
                    if let idx = store.bindings.firstIndex(where: { $0.id == saved.id }) {
                        store.bindings[idx] = saved
                    } else {
                        store.bindings.append(saved)
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    private func validate(_ cfg: HotkeyConfig, excluding id: UUID?) -> String? {
        if cfg.isPureModifier { return "Modifier-only triggers are not allowed" }
        if cfg.modifiers.isEmpty, !HotkeyConfig.functionRowKeyCodes.contains(cfg.keyCode) {
            return "Need at least one modifier"
        }
        if cfg.isSystemReserved { return "\(cfg.displayString()) is reserved by macOS" }
        let excluding = id.map { HotkeyRegistry.Owner.hotkeyBinding(id: $0) }
        if let first = HotkeyRegistry.shared.conflicts(for: cfg, excluding: excluding).first {
            return "Conflicts with: \(first.purpose)"
        }
        return nil
    }
}

private struct ShortcutRow: View {
    @Binding var binding: HotkeyBinding
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(triggerDisplay)
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .leading)

            Text(summary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $binding.enabled)
                .labelsHidden()
                .controlSize(.mini)

            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.borderless)

            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var triggerDisplay: String {
        HotkeyConfig.parse(binding.trigger)?.displayString() ?? binding.trigger
    }

    private var summary: String {
        binding.actions.map(HotkeyActionFormatter.summarize).joined(separator: " → ")
    }
}

enum HotkeyActionFormatter {
    static func summarize(_ a: HotkeyAction) -> String {
        switch a {
        case .typeText(let s):
            let trimmed = s.count > 20 ? String(s.prefix(20)) + "…" : s
            return "type \"\(trimmed)\""
        case .keyPress(let kc, let mods):
            let cfg = HotkeyConfig(modifiers: CGEventFlags(rawValue: mods), keyCode: CGKeyCode(kc))
            return "press \(cfg.displayString())"
        case .wait(let ms):
            return "wait \(ms)ms"
        case .shell(let cmd):
            let trimmed = cmd.count > 24 ? String(cmd.prefix(24)) + "…" : cmd
            return "run \"\(trimmed)\""
        }
    }
}

// MARK: - Binding editor sheet

private struct BindingEditorSheet: View {
    let original: HotkeyBinding
    let isNew: Bool
    let validator: (HotkeyConfig) -> String?
    let onSave: (HotkeyBinding) -> Void
    let onCancel: () -> Void

    @State private var trigger: HotkeyConfig?
    @State private var actions: [ActionDraft]
    @State private var appBundleIDs: [String]
    @State private var error: String?

    init(
        original: HotkeyBinding,
        isNew: Bool,
        validator: @escaping (HotkeyConfig) -> String?,
        onSave: @escaping (HotkeyBinding) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.original = original
        self.isNew = isNew
        self.validator = validator
        self.onSave = onSave
        self.onCancel = onCancel
        _trigger = State(initialValue: HotkeyConfig.parse(original.trigger))
        _actions = State(initialValue: original.actions.map(ActionDraft.init))
        _appBundleIDs = State(initialValue: original.appBundleIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledRow("Hotkey:") {
                        HotkeyRecorderConfigWithClear(
                            config: $trigger,
                            mode: .combo,
                            validator: validator,
                            recorderWidth: 220
                        )
                    }

                    LabeledRow(
                        "Apps:",
                        help:
                            "Leave empty to make this shortcut work in all apps. Add apps to limit it to those running applications."
                    ) {
                        AppsScopeView(bundleIDs: $appBundleIDs)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Actions")
                            .font(.headline)

                        VStack(spacing: 8) {
                            ForEach($actions) { $action in
                                ActionDraftRow(action: $action) {
                                    actions.removeAll { $0.id == action.id }
                                }
                            }
                        }

                        Button {
                            actions.append(ActionDraft())
                        } label: {
                            Label("Add Action", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Text("Shell actions run with your full user privileges. Only add shortcuts you trust.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .navigationTitle(isNew ? "New Shortcut" : "Edit Shortcut")
    }

    private func save() {
        guard let trigger else {
            error = "Set a hotkey first"
            return
        }
        if let msg = validator(trigger) {
            error = msg
            return
        }
        if actions.isEmpty {
            error = "Add at least one action"
            return
        }
        if let badIdx = actions.firstIndex(where: { !$0.isValid }) {
            error = "Action \(badIdx + 1) is incomplete or invalid"
            return
        }
        let saved = HotkeyBinding(
            id: original.id,
            trigger: trigger.encode(),
            actions: actions.map { $0.toAction() },
            enabled: original.enabled,
            appBundleIDs: appBundleIDs
        )
        onSave(saved)
    }
}

// MARK: - Binding editor: action draft

private struct ActionDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case typeText, keyPress, wait, shell
        var id: String { rawValue }
        var label: String {
            switch self {
            case .typeText: String(localized: "Text")
            case .keyPress: String(localized: "Key")
            case .wait: String(localized: "Wait")
            case .shell: String(localized: "Shell")
            }
        }
    }

    let id = UUID()
    var kind: Kind = .typeText
    var text: String = ""

    init() {}

    init(_ action: HotkeyAction) {
        switch action {
        case .typeText(let s):
            kind = .typeText
            text = s
        case .keyPress(let kc, let mods):
            kind = .keyPress
            text = HotkeyConfig(modifiers: CGEventFlags(rawValue: mods), keyCode: CGKeyCode(kc)).encode()
        case .wait(let ms):
            kind = .wait
            text = String(ms)
        case .shell(let cmd):
            kind = .shell
            text = cmd
        }
    }

    var isValid: Bool {
        switch kind {
        case .typeText: return !text.isEmpty
        case .keyPress:
            guard let cfg = HotkeyConfig.parse(text) else { return false }
            return !cfg.isPureModifier
        case .wait: return Int(text) != nil
        case .shell: return !text.isEmpty
        }
    }

    func toAction() -> HotkeyAction {
        switch kind {
        case .typeText: return .typeText(text)
        case .keyPress:
            if let cfg = HotkeyConfig.parse(text), !cfg.isPureModifier {
                return .keyPress(keyCode: UInt16(cfg.keyCode), modifiers: cfg.modifiers.rawValue)
            }
            return .keyPress(keyCode: 0, modifiers: 0)
        case .wait: return .wait(ms: max(0, Int(text) ?? 100))
        case .shell: return .shell(text)
        }
    }
}

private struct ActionDraftRow: View {
    @Binding var action: ActionDraft
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $action.kind) {
                ForEach(ActionDraft.Kind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            TextField("", text: $action.text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(action.isValid ? Color.clear : Color.red.opacity(0.7), lineWidth: 1)
                )

            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var placeholder: String {
        switch action.kind {
        case .typeText: String(localized: "Text to type")
        case .keyPress: String(localized: "e.g. cmd+shift+a")
        case .wait: String(localized: "Milliseconds")
        case .shell: String(localized: "Shell command")
        }
    }
}

// MARK: - Labeled row helper

private struct LabeledRow<Content: View>: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey?
    let content: Content

    init(_ title: LocalizedStringKey, help: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 4) {
                Text(title).fontWeight(.medium)
                if let help {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help(help)
                }
            }
            .frame(width: 70, alignment: .leading)

            content

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Apps scope picker

private struct AppsScopeView: View {
    @Binding var bundleIDs: [String]
    @State private var pickerOpen = false

    var body: some View {
        HStack(spacing: 6) {
            if bundleIDs.isEmpty {
                Text("Global (all apps)")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bundleIDs, id: \.self) { bid in
                    AppChip(bundleID: bid) {
                        bundleIDs.removeAll { $0 == bid }
                    }
                }
            }

            Button {
                pickerOpen = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                AppPickerList(excluding: Set(bundleIDs)) { bid in
                    if !bundleIDs.contains(bid) { bundleIDs.append(bid) }
                    pickerOpen = false
                }
            }
        }
    }
}

private struct AppChip: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let info = AppInfo.lookup(bundleID: bundleID)
        return HStack(spacing: 5) {
            if let img = info.icon {
                Image(nsImage: img).resizable().frame(width: 16, height: 16)
            }
            Text(info.name).font(.callout).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

private struct AppPickerList: View {
    let excluding: Set<String>
    let onPick: (String) -> Void

    private var apps: [AppInfo] {
        let seen = excluding
        var unique = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppInfo? in
                guard let bid = app.bundleIdentifier, !seen.contains(bid),
                    unique.insert(bid).inserted
                else { return nil }
                return AppInfo(bundleID: bid, name: app.localizedName ?? bid, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if apps.isEmpty {
                        Text("No other running apps")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(apps) { app in
                            Button {
                                onPick(app.bundleID)
                            } label: {
                                HStack(spacing: 8) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                    }
                                    Text(app.name).font(.callout)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider().padding(.vertical, 2)

                    Button(action: pickOtherApp) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .frame(width: 16, height: 16)
                                .foregroundStyle(.secondary)
                            Text("Other apps…").font(.callout)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 240, height: 280)
    }

    private func pickOtherApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an Application")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url,
            let bundle = Bundle(url: url),
            let bid = bundle.bundleIdentifier
        {
            onPick(bid)
        }
    }
}

private struct AppInfo: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: String { bundleID }

    static func lookup(bundleID: String) -> AppInfo {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let values = try? url.resourceValues(forKeys: [.localizedNameKey])
            let name = values?.localizedName ?? url.deletingPathExtension().lastPathComponent
            return AppInfo(bundleID: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        return AppInfo(bundleID: bundleID, name: bundleID, icon: nil)
    }
}

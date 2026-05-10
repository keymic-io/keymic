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
        title = "KeyMic Settings"
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
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Default hotkey strings

/// Single source of truth for hotkey defaults. Values match the fallbacks
/// used in `KeyMonitor`, `AppDelegate`, and the `@AppStorage` initializers
/// below — keep them in sync.
enum HotkeyDefaults {
    static let settings      = "cmd+shift+,"
    static let voiceTrigger  = "fn"
    static let clipboard     = "alt+v"
    static let vault         = "alt+b"
    static let screenshot    = "ctrl+shift+a"
}

// MARK: - Sections

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, voice, llm, personas, keyMapping, shortcuts, clipboard, screenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    "General"
        case .voice:      "Voice"
        case .llm:        "LLM"
        case .personas:   "Personas"
        case .keyMapping: "Key Mapping"
        case .shortcuts:  "Shortcuts"
        case .clipboard:  "Clipboard"
        case .screenshot: "Screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .general:    "gearshape"
        case .voice:      "mic"
        case .llm:        "sparkles"
        case .personas:   "person.crop.circle.badge.checkmark"
        case .keyMapping: "keyboard"
        case .shortcuts:  "command.square"
        case .clipboard:  "doc.on.clipboard"
        case .screenshot: "camera.on.rectangle"
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
        case .general:    GeneralSettingsView()
        case .voice:      VoiceSettingsView()
        case .llm:        LLMSettingsView()
        case .personas:   PersonasView()
        case .clipboard:  ClipboardSettingsView()
        case .keyMapping: KeyMappingSettingsSection()
        case .shortcuts:  ShortcutsSettingsSection()
        case .screenshot: ScreenshotSettingsView()
        }
    }
}

// MARK: - Screenshot

private struct ScreenshotSettingsView: View {
    @AppStorage("screenshotEnabled") private var screenshotEnabled: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable screenshot hotkey ⌃⇧A", isOn: $screenshotEnabled)
            } header: {
                Text("Screenshot")
            } footer: {
                Text("Press ⌃⇧A to capture a region of the screen and open it in the annotation editor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("settingsHotkey") private var settingsHotkey: String = "cmd+shift+,"
    @AppStorage("automaticallyUpdates") private var automaticallyUpdates: Bool = true
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()

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
                Toggle("Automatically check and install updates", isOn: $automaticallyUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("When enabled, KeyMic checks for updates daily at 11:00 AM and installs them silently. When disabled, you'll be prompted to review updates before installing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Open Settings:") {
                    HotkeyRecorderWithClear(
                        encoded: $settingsHotkey,
                        defaultEncoded: HotkeyDefaults.settings,
                        mode: .combo,
                        validator: settingsValidator,
                        recorderWidth: 200
                    )
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Global shortcut to open this Settings window from anywhere.")
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
                    Text("KeyMic needs Accessibility to monitor the trigger key, apply key mappings, and synthesize paste.")
                    + Text("  ") +
                    Text("Version \(Bundle.main.appVersion)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
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

    private func settingsValidator(_ cfg: HotkeyConfig) -> String? {
        if cfg.isPureModifier { return "Need a key, not just modifiers" }
        if cfg.modifiers.isEmpty { return "Need at least one modifier" }
        if cfg.isSystemReserved { return "\(cfg.displayString()) is reserved by macOS" }
        let voiceKey = UserDefaults.standard.string(forKey: "voiceTriggerKey") ?? "fn"
        let clipKey = UserDefaults.standard.string(forKey: "clipboardHotkey") ?? "alt+v"
        let vaultKey = UserDefaults.standard.string(forKey: "vaultHotkey") ?? "alt+b"
        if HotkeyConfig.parse(voiceKey) == cfg { return "Conflicts with voice trigger" }
        if HotkeyConfig.parse(clipKey) == cfg { return "Conflicts with clipboard hotkey" }
        if HotkeyConfig.parse(vaultKey) == cfg { return "Conflicts with vault hotkey" }
        return nil
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

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - Voice

private struct VoiceSettingsView: View {
    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @AppStorage("voiceTriggerKey") private var triggerKey: String = "fn"
    @AppStorage("selectedLocaleCode") private var localeCode: String = ""

    private static let languages: [SpeechLanguageOption] = SFSpeechRecognizer.supportedLocales()
        .map { SpeechLanguageOption(locale: $0) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private var selectedLanguageCode: Binding<String> {
        Binding(
            get: { localeCode.isEmpty ? Locale.current.identifier : localeCode },
            set: { localeCode = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable voice input", isOn: $voiceEnabled)
            }

            Section {
                Picker("Language:", selection: selectedLanguageCode) {
                    ForEach(Self.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } footer: {
                Text("If no language has been selected, KeyMic shows the current system language. After you choose one, KeyMic uses its own language setting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Trigger Key:") {
                    HotkeyRecorderWithClear(
                        encoded: $triggerKey,
                        defaultEncoded: HotkeyDefaults.voiceTrigger,
                        mode: .pureModifier,
                        validator: HotkeyRecorder.voiceValidator,
                        recorderWidth: 220
                    )
                }
            } footer: {
                Text("Hold the trigger key to dictate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpeechLanguageOption: Identifiable {
    let code: String
    let name: String

    var id: String { code }

    init(locale: Locale) {
        code = locale.identifier
        name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

// MARK: - LLM

private struct LLMSettingsView: View {
    @AppStorage("llmAPIBaseURL") private var apiBaseURL: String = "https://api.openai.com/v1"
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
            case .testing: return "Testing…"
            case .ok(let m): return "OK: \(m)"
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
    private func llmFieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(label):")
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
        let refiner = LLMRefiner.shared
        guard refiner.isReady else {
            status = .fail("API key is empty")
            return
        }
        status = .testing
        refiner.refine(
            "Hello, this is a test.",
            systemPrompt: "Return the input exactly as-is.",
            temperature: 0.0
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text): status = .ok(text)
                case .failure(let err):  status = .fail(err.localizedDescription)
                }
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
    @AppStorage("clipboardHotkey") private var hotkey: String = "alt+v"
    @AppStorage("vaultHotkey") private var vaultHotkey: String = "alt+b"

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
                        encoded: $hotkey,
                        defaultEncoded: HotkeyDefaults.clipboard,
                        mode: .combo,
                        validator: clipboardHotkeyValidator,
                        recorderWidth: 160
                    )
                }
                LabeledContent("Open Vault:") {
                    HotkeyRecorderWithClear(
                        encoded: $vaultHotkey,
                        defaultEncoded: HotkeyDefaults.vault,
                        mode: .combo,
                        validator: vaultHotkeyValidator,
                        recorderWidth: 160
                    )
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

    private func clipboardHotkeyValidator(_ cfg: HotkeyConfig) -> String? {
        if let message = HotkeyRecorder.clipboardValidator(cfg) { return message }
        if HotkeyConfig.parse(vaultHotkey) == cfg { return "Conflicts with vault hotkey" }
        return nil
    }

    private func vaultHotkeyValidator(_ cfg: HotkeyConfig) -> String? {
        if let message = HotkeyRecorder.clipboardValidator(cfg) { return message }
        if HotkeyConfig.parse(hotkey) == cfg { return "Conflicts with clipboard hotkey" }
        return nil
    }
}

// MARK: - HotkeyRecorder bridge

struct HotkeyRecorderField: NSViewRepresentable {
    typealias DisplayName = (HotkeyConfig) -> String

    @Binding var config: HotkeyConfig?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let displayName: DisplayName?

    init(
        config: Binding<HotkeyConfig?>,
        mode: HotkeyRecorder.Mode,
        validator: @escaping HotkeyRecorder.Validator,
        displayName: DisplayName? = nil
    ) {
        self._config = config
        self.mode = mode
        self.validator = validator
        self.displayName = displayName
    }

    /// Convenience initializer that bridges to a UserDefaults-backed encoded string.
    init(
        encoded: Binding<String>,
        mode: HotkeyRecorder.Mode,
        validator: @escaping HotkeyRecorder.Validator
    ) {
        self.init(
            config: Binding(
                get: { HotkeyConfig.parse(encoded.wrappedValue) },
                set: { encoded.wrappedValue = $0?.encode() ?? "" }
            ),
            mode: mode,
            validator: validator,
            displayName: nil
        )
    }

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
        var parent: HotkeyRecorderField
        weak var recorder: HotkeyRecorder?
        var lastConfig: HotkeyConfig?
        init(parent: HotkeyRecorderField) { self.parent = parent }

        func refreshTitle() {
            guard let recorder, let name = parent.displayName, let cfg = parent.config else { return }
            recorder.title = name(cfg)
        }
    }
}

// MARK: - HotkeyRecorder with clear / restore-default button

/// Recorder bound to a UserDefaults-backed encoded string, with a trailing "×"
/// button that restores the default (or clears, when no default is provided).
struct HotkeyRecorderWithClear: View {
    @Binding var encoded: String
    let defaultEncoded: String?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let recorderWidth: CGFloat

    private var canReset: Bool {
        if let defaultEncoded { return encoded != defaultEncoded }
        return !encoded.isEmpty
    }

    var body: some View {
        HStack(spacing: 4) {
            HotkeyRecorderField(encoded: $encoded, mode: mode, validator: validator)
                .frame(width: recorderWidth, height: 24)

            ClearHotkeyButton(
                hasDefault: defaultEncoded != nil,
                isEnabled: canReset,
                action: { encoded = defaultEncoded ?? "" }
            )
        }
    }
}

/// Recorder bound to a `HotkeyConfig?`, with a trailing "×" button that
/// restores the default (or clears the value, when no default is provided).
struct HotkeyRecorderConfigWithClear: View {
    @Binding var config: HotkeyConfig?
    let defaultConfig: HotkeyConfig?
    let mode: HotkeyRecorder.Mode
    let validator: HotkeyRecorder.Validator
    let displayName: HotkeyRecorderField.DisplayName?
    let recorderWidth: CGFloat

    init(
        config: Binding<HotkeyConfig?>,
        defaultConfig: HotkeyConfig? = nil,
        mode: HotkeyRecorder.Mode,
        validator: @escaping HotkeyRecorder.Validator,
        displayName: HotkeyRecorderField.DisplayName? = nil,
        recorderWidth: CGFloat
    ) {
        self._config = config
        self.defaultConfig = defaultConfig
        self.mode = mode
        self.validator = validator
        self.displayName = displayName
        self.recorderWidth = recorderWidth
    }

    private var canReset: Bool {
        if let defaultConfig { return config != defaultConfig }
        return config != nil
    }

    var body: some View {
        HStack(spacing: 4) {
            HotkeyRecorderField(
                config: $config,
                mode: mode,
                validator: validator,
                displayName: displayName
            )
            .frame(width: recorderWidth, height: 24)

            ClearHotkeyButton(
                hasDefault: defaultConfig != nil,
                isEnabled: canReset,
                action: { config = defaultConfig }
            )
        }
    }
}

/// Compact "×" button shared by both recorder wrappers. Keeps layout stable
/// by reserving space via `.opacity` rather than removing the view.
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
                Text("Trigger any text input, key press, or shell script with a hotkey combo. Shell actions run with your full user privileges — only add shortcuts you trust.")
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
        if cfg.modifiers.isEmpty { return "Need at least one modifier" }
        let voiceKey = UserDefaults.standard.string(forKey: "voiceTriggerKey") ?? "fn"
        let clipKey = UserDefaults.standard.string(forKey: "clipboardHotkey") ?? "alt+v"
        if HotkeyConfig.parse(voiceKey) == cfg { return "Conflicts with voice trigger" }
        if HotkeyConfig.parse(clipKey) == cfg { return "Conflicts with clipboard hotkey" }
        if store.bindings.contains(where: { $0.id != id && HotkeyConfig.parse($0.trigger) == cfg }) {
            return "Conflicts with existing shortcut"
        }
        if cfg.isSystemReserved { return "\(cfg.displayString()) is reserved by macOS" }
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
                        help: "Leave empty to make this shortcut work in all apps. Add apps to limit it to those running applications."
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
        guard let trigger else { error = "Set a hotkey first"; return }
        if let msg = validator(trigger) { error = msg; return }
        if actions.isEmpty { error = "Add at least one action"; return }
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
            case .typeText: "Text"
            case .keyPress: "Key"
            case .wait:     "Wait"
            case .shell:    "Shell"
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
            kind = .typeText; text = s
        case .keyPress(let kc, let mods):
            kind = .keyPress
            text = HotkeyConfig(modifiers: CGEventFlags(rawValue: mods), keyCode: CGKeyCode(kc)).encode()
        case .wait(let ms):
            kind = .wait; text = String(ms)
        case .shell(let cmd):
            kind = .shell; text = cmd
        }
    }

    var isValid: Bool {
        switch kind {
        case .typeText: return !text.isEmpty
        case .keyPress:
            guard let cfg = HotkeyConfig.parse(text) else { return false }
            return !cfg.isPureModifier
        case .wait:     return Int(text) != nil
        case .shell:    return !text.isEmpty
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
        case .wait:     return .wait(ms: max(0, Int(text) ?? 100))
        case .shell:    return .shell(text)
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
        case .typeText: "Text to type"
        case .keyPress: "e.g. cmd+shift+a"
        case .wait:     "Milliseconds"
        case .shell:    "Shell command"
        }
    }
}

// MARK: - Labeled row helper

private struct LabeledRow<Content: View>: View {
    let title: String
    let help: String?
    let content: Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
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
                      unique.insert(bid).inserted else { return nil }
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
        panel.title = "Choose an Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url),
           let bid = bundle.bundleIdentifier {
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

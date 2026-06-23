import SwiftUI

struct MeetingSettingsView: View {
    // Set by AppDelegate (Task 5) once the controller/store exist. Mirrors the
    // shared-singleton access pattern other settings views use.
    @State private var controller = MeetingRuntime.shared.controller
    private var store: TranscriptStore? { MeetingRuntime.shared.store }

    @State private var hotkeyStore = HotkeySettingsStore.shared
    @State private var hotkeyResetError: String?
    @State private var audioSource: MeetingAudioSource = MeetingPreferences.audioSource()
    @State private var showClearAllHistory = false

    private var hotkey: Binding<String> { hotkeyBinding(hotkeyStore, for: .meetingTranscribe) }

    private var isTranscribing: Bool { controller?.isTranscribing ?? false }

    var body: some View {
        Form {
            // General: status + Start/Stop + hotkey
            Section {
                LabeledContent("Status:") {
                    HStack(spacing: 8) {
                        Circle().fill(isTranscribing ? .red : .secondary).frame(width: 8, height: 8)
                        Text(isTranscribing ? "Recording" : "Idle").foregroundStyle(.secondary)
                        Spacer()
                        if isTranscribing {
                            Button("Stop") { controller?.stop() }.tint(.red)
                        } else {
                            Button("Start") { controller?.start() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                LabeledContent("Hotkey:") {
                    HotkeyRecorderWithClear(
                        encoded: hotkey,
                        defaultEncoded: HotkeyFeature.defaults[HotkeyFeature.meetingTranscribe.rawValue]!,
                        mode: .combo,
                        validator: { hotkeyStore.validationMessage(for: $0, owner: .feature(.meetingTranscribe)) },
                        recorderWidth: 160,
                        resetAction: { hotkeyResetError = resetHotkey(hotkeyStore, for: .meetingTranscribe) })
                }
                .disabled(isTranscribing)
                if let hotkeyResetError {
                    Text(hotkeyResetError).font(.callout).foregroundStyle(.red)
                }
            } header: { Text("General") } footer: {
                Text("Press the hotkey or use the menu bar to start / stop a meeting. Start downloads the model or requests permission if needed.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            // Audio source
            Section {
                Picker("Capture:", selection: Binding(
                    get: { audioSource },
                    set: { audioSource = $0; MeetingPreferences.setAudioSource($0) })) {
                    Text("Mic").tag(MeetingAudioSource.mic)
                    Text("System").tag(MeetingAudioSource.system)
                    Text("Both").tag(MeetingAudioSource.both)
                }
                .pickerStyle(.segmented)
                .disabled(isTranscribing)
            } header: { Text("Audio source") } footer: {
                Text("「Both」分别识别本人(我)与系统音频(对方)。准确区分需佩戴耳机以避免外放串音。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            // History (M4)
            Section {
                if let store { MeetingHistoryView(store: store) }
                else { Text("History unavailable").foregroundStyle(.secondary) }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    Button(role: .destructive) {
                        showClearAllHistory = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(store == nil)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Delete all meeting history?"),
            isPresented: $showClearAllHistory,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { store?.deleteAllSessions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every meeting and its transcript. This cannot be undone.")
        }
        .onAppear { audioSource = MeetingPreferences.audioSource() }
    }
}

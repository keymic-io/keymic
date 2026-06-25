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

    // Diarization models (P2.2). Reuses the Voice tab's runtime+model download controller —
    // downloading is the opt-in; MeetingDiarizer runs automatically once the model is ready.
    @StateObject private var diarization = OnnxDownloadController(modelStore: OnnxStores.diarization)

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

            // Speaker diarization model (P2.2) — optional, reuses the ONNX download row.
            Section {
                let fraction: Double? = {
                    if case .downloading(let f) = diarization.combined { return f }
                    return nil
                }()
                let busy: Bool = {
                    switch diarization.combined {
                    case .ready, .downloading: return true
                    case .notDownloaded, .failed: return false
                    }
                }()
                ModelDownloadRow(
                    statusText: modelStatusText(DownloadPhase(diarization.combined), sizeText: "≈ 33 MB"),
                    fraction: fraction,
                    isReady: diarization.combined == .ready,
                    downloadTitle: "Download runtime + model",
                    downloadDisabled: busy,
                    folderURL: OnnxStores.diarization.destDir,
                    onDownload: { diarization.download() })
            } header: {
                Text("Speaker diarization")
            } footer: {
                Text("下载后,会议结束会自动把远端说话人拆分为「对方 1 / 2 / 3」并写入历史;不下载则远端统一标为「对方」。仅作用于系统音频(对方)一路。")
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

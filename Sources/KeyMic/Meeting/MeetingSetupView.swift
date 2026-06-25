import AVFoundation
import CoreGraphics
import SwiftUI
import os

/// Maps AVFoundation's authorization status onto the UI-facing `MicPermission`. Lives here (not in
/// the pure `MeetingPrerequisites.swift`) so that file stays AVFoundation-free for its test target.
extension MicPermission {
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        default: self = .denied   // .denied + .restricted + any future case
        }
    }
}

extension ScreenRecordingPermission {
    init(authorized: Bool) { self = authorized ? .authorized : .denied }
}

extension MeetingPrerequisites {
    /// Snapshot of the live prerequisite sources for a given audio source. Screen Recording is
    /// only required (and only read) when system audio is captured (`.both`/`.system`).
    static func live(source: MeetingAudioSource) -> MeetingPrerequisites {
        let needsScreen = (source == .both || source == .system)
        return MeetingPrerequisites(
            // .ready == downloaded, not dlopen'd; loading is the pipeline's backstop (design spec §7).
            mic: MicPermission(AVCaptureDevice.authorizationStatus(for: .audio)),
            runtimeReady: ONNXRuntimeLoader.shared.store.state == .ready,
            modelReady: OnnxStores.streaming.state == .ready,
            requiresScreenRecording: needsScreen,
            screenRecording: needsScreen
                ? ScreenRecordingPermission(authorized: CGPreflightScreenCaptureAccess())
                : .authorized)
    }
}

/// Observable backing for `MeetingSetupView`. Owns the runtime+model download controller and a
/// refreshable mic-permission value. `OnnxDownloadController` already hops its `AssetStore`
/// observers to main and exposes a `combined` runtime+model state, so the model row is a thin
/// projection of it.
@MainActor
final class MeetingSetupModel: ObservableObject {
    @Published var mic: MicPermission
    @Published var screenRecording: ScreenRecordingPermission
    @Published var audioSource: MeetingAudioSource
    let onnx: OnnxDownloadController

    init() {
        self.mic = MicPermission(AVCaptureDevice.authorizationStatus(for: .audio))
        self.audioSource = MeetingPreferences.audioSource()
        self.screenRecording = ScreenRecordingPermission(authorized: CGPreflightScreenCaptureAccess())
        self.onnx = OnnxDownloadController(modelStore: OnnxStores.streaming)
        // Punctuation post-processing models, fire-and-forget + idempotent (no-op if already
        // downloaded; back-fills users who already have the streaming model). Missing → pipeline
        // degrades to raw text for that language. English truecasing+punct (~7 MB) + Chinese
        // CT-transformer punct (~72 MB).
        OnnxStores.punct.ensureDownloaded { _ in }
        OnnxStores.ctPunct.ensureDownloaded { _ in }
    }

    /// Re-read mic + screen-recording permission and the selected audio source. Called when the
    /// window appears and on focus (the user may have changed a grant in System Settings).
    func refresh() {
        mic = MicPermission(AVCaptureDevice.authorizationStatus(for: .audio))
        audioSource = MeetingPreferences.audioSource()
        screenRecording = ScreenRecordingPermission(authorized: CGPreflightScreenCaptureAccess())
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Prompts once if undetermined; after a denial macOS requires the System Settings hand-off.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    var prerequisites: MeetingPrerequisites {
        let needsScreen = (audioSource == .both || audioSource == .system)
        return MeetingPrerequisites(
            mic: mic,
            runtimeReady: onnx.runtimeState == .ready,
            modelReady: onnx.modelState == .ready,
            requiresScreenRecording: needsScreen,
            screenRecording: screenRecording)
    }
}

/// Checklist-style guided setup for meeting transcription: one row for microphone permission and
/// one for the combined runtime+model download. "Start transcription" enables only when every
/// prerequisite is satisfied (`MeetingPrerequisites.allReady`).
struct MeetingSetupView: View {
    @ObservedObject var model: MeetingSetupModel
    let onGrantMic: () -> Void
    let onOpenMicSettings: () -> Void
    let onGrantScreen: () -> Void
    let onOpenScreenSettings: () -> Void
    let onDownloadModel: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    /// Total runtime + streaming model download (~61 MB runtime + ~190 MB model, measured 2026-06-23).
    private static let modelSizeText = "≈ 250 MB"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up meeting transcription")
                .font(.headline)
            Text("Resolve the items below, then start transcribing.")
                .font(.callout)
                .foregroundStyle(.secondary)

            micRow
            if model.audioSource == .both || model.audioSource == .system {
                Divider()
                screenRow
            }
            Divider()
            modelRow

            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Start transcription", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.prerequisites.allReady)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    // MARK: Microphone row

    @ViewBuilder
    private var micRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph(model.mic == .authorized)
            VStack(alignment: .leading, spacing: 4) {
                Text("Microphone access").font(.body.weight(.medium))
                switch model.mic {
                case .authorized:
                    Text("Granted.").font(.callout).foregroundStyle(.secondary)
                case .notDetermined:
                    Text("KeyMic needs the microphone to transcribe what you say.")
                        .font(.callout).foregroundStyle(.secondary)
                case .denied:
                    Text("Microphone access is off. Enable KeyMic under System Settings → Privacy & Security → Microphone, then return here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch model.mic {
            case .authorized:
                EmptyView()
            case .notDetermined:
                Button("Grant", action: onGrantMic)
            case .denied:
                Button("Open System Settings", action: onOpenMicSettings)
            }
        }
    }

    // MARK: Screen Recording row

    @ViewBuilder
    private var screenRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph(model.screenRecording == .authorized)
            VStack(alignment: .leading, spacing: 4) {
                Text("Screen Recording access").font(.body.weight(.medium))
                switch model.screenRecording {
                case .authorized:
                    Text("Granted.").font(.callout).foregroundStyle(.secondary)
                case .denied:
                    Text("KeyMic needs Screen Recording to capture the other party's audio. Enable KeyMic under System Settings → Privacy & Security → Screen Recording, then return here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch model.screenRecording {
            case .authorized:
                EmptyView()
            case .denied:
                Button("Open System Settings", action: onOpenScreenSettings)
            }
        }
    }

    // MARK: Recognition-model row

    @ViewBuilder
    private var modelRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph(model.onnx.combined == .ready)
            VStack(alignment: .leading, spacing: 6) {
                Text("Recognition model").font(.body.weight(.medium))
                modelStatusContent
            }
            Spacer()
            modelTrailingControl
        }
    }

    @ViewBuilder
    private var modelStatusContent: some View {
        switch model.onnx.combined {
        case .ready:
            Text("Ready.").font(.callout).foregroundStyle(.secondary)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                    .frame(width: 220)
                Text(String(format: String(localized: "Downloading… %lld%%"), Int((fraction * 100).rounded())))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(String(format: String(localized: "Download failed: %@"), message))
                .font(.callout).foregroundStyle(.red)
        case .notDownloaded:
            Text("The on-device transcription model has not been downloaded yet.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var modelTrailingControl: some View {
        switch model.onnx.combined {
        case .ready, .downloading:
            EmptyView()
        case .notDownloaded:
            Button(String(format: String(localized: "Download (%@)"), Self.modelSizeText), action: onDownloadModel)
        case .failed:
            Button("Retry", action: onDownloadModel)
        }
    }

    private func statusGlyph(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color.green : Color.secondary)
            .font(.title3)
            .frame(width: 22)
    }
}

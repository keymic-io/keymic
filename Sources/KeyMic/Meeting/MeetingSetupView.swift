import AVFoundation
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

extension MeetingPrerequisites {
    /// Snapshot of the three live prerequisite sources. Used by `AppDelegate` to drive the gate.
    static func live() -> MeetingPrerequisites {
        MeetingPrerequisites(
            mic: MicPermission(AVCaptureDevice.authorizationStatus(for: .audio)),
            runtimeReady: ONNXRuntimeLoader.shared.store.state == .ready, // .ready == downloaded, not dlopen'd; loading is the pipeline's backstop (design spec §7).
            modelReady: OnnxStores.streaming.state == .ready)
    }
}

/// Observable backing for `MeetingSetupView`. Owns the runtime+model download controller and a
/// refreshable mic-permission value. `OnnxDownloadController` already hops its `AssetStore`
/// observers to main and exposes a `combined` runtime+model state, so the model row is a thin
/// projection of it.
@MainActor
final class MeetingSetupModel: ObservableObject {
    @Published var mic: MicPermission
    let onnx: OnnxDownloadController

    init() {
        self.mic = MicPermission(AVCaptureDevice.authorizationStatus(for: .audio))
        self.onnx = OnnxDownloadController(modelStore: OnnxStores.streaming)
    }

    /// Re-read mic status (the user may have toggled it in System Settings while the window was up).
    func refreshMic() {
        mic = MicPermission(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// In-app system prompt — only meaningful from `.notDetermined`.
    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMic() }
        }
    }

    var prerequisites: MeetingPrerequisites {
        MeetingPrerequisites(
            mic: mic,
            runtimeReady: onnx.runtimeState == .ready,
            modelReady: onnx.modelState == .ready)
    }
}

/// Checklist-style guided setup for meeting transcription: one row for microphone permission and
/// one for the combined runtime+model download. "Start transcription" enables only when every
/// prerequisite is satisfied (`MeetingPrerequisites.allReady`).
struct MeetingSetupView: View {
    @ObservedObject var model: MeetingSetupModel
    let onGrantMic: () -> Void
    let onOpenMicSettings: () -> Void
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

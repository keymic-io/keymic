import AppKit
import SwiftUI

/// Guided setup panel shown when `MeetingController.start()` is blocked by a missing prerequisite.
/// Hosts `MeetingSetupView`. Can become key (its buttons need clicks). Cancel just closes it;
/// "Start transcription" invokes the injected `onStart` — which calls back into the normal
/// `MeetingController.start()` path, now passing the gate.
final class MeetingSetupWindow: NSPanel {
    private let model = MeetingSetupModel()
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), // Height is governed by the hosted SwiftUI content (NSHostingController sizes to fit); the literal is just an initial nominal.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        title = String(localized: "Meeting Setup")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let view = MeetingSetupView(
            model: model,
            onGrantMic: { [weak self] in self?.model.requestMic() },
            onOpenMicSettings: { Self.openMicSystemSettings() },
            onDownloadModel: { [weak self] in self?.model.onnx.download() },
            onStart: { [weak self] in self?.handleStart() },
            onCancel: { [weak self] in self?.close() })
        contentViewController = NSHostingController(rootView: view)
        center()
    }

    override var canBecomeKey: Bool { true }

    /// Re-check mic permission whenever the window regains focus — the user may have granted it in
    /// System Settings while this window was open.
    override func becomeKey() {
        super.becomeKey()
        model.refreshMic()
    }

    /// Present (or re-present) the window with a fresh mic read.
    func presentRefreshed() {
        model.refreshMic()
        makeKeyAndOrderFront(nil)
    }

    private func handleStart() {
        close()
        onStart()
    }

    private static func openMicSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

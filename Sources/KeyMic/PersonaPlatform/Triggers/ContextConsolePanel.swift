import AppKit
import SwiftUI

@MainActor
final class ContextConsolePanel: NSPanel {
    private let state: ContextConsoleState
    private let onContinue: () -> Void
    private let onCancel: () -> Void
    private static let defaultSize = NSSize(width: 460, height: 340)

    init(state: ContextConsoleState,
         onContinue: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.state = state
        self.onContinue = onContinue
        self.onCancel = onCancel
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        let view = ContextConsoleView(
            state: state,
            onContinue: { [weak self] in self?.onContinue() },
            onCancel: { [weak self] in self?.onCancel() }
        )
        let host = NSHostingController(rootView: view)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host.view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    func present() {
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: v.midX - frame.width / 2,
                y: v.midY - frame.height / 2
            ))
        }
        orderFrontRegardless()
        makeKey()
    }
}

private struct ContextConsoleView: View {
    @Bindable var state: ContextConsoleState
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Refine & send")
                .font(.system(size: 13, weight: .semibold))

            TextEditor(text: $state.transcript)
                .font(.system(size: 13))
                .frame(minHeight: 80)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            Text("Context")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach($state.candidates) { $cand in
                        Toggle(isOn: $cand.isChecked) {
                            HStack(spacing: 6) {
                                Text(kindLabel(cand.kind)).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(cand.text).font(.system(size: 12)).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 120)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.isRunning)
            }
        }
        .padding(16)
        .frame(width: 460, height: 340)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        )
    }

    private func kindLabel(_ kind: ContextCandidate.Kind) -> String {
        switch kind {
        case .selection: return String(localized: "Selection")
        case .clipboardTop: return String(localized: "Clipboard")
        case .clipboardHistory: return String(localized: "History")
        }
    }
}

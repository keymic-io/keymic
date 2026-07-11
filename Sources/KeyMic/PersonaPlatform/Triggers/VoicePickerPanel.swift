import AppKit
import Observation
import SwiftUI

// MARK: - State

@Observable
@MainActor
final class VoicePickerState {
    var entries: [PickerEntry] = [.defaultInput]
    var highlightedIndex: Int = 0
    /// Trigger-down context snapshot (AX selection + clipboard top).
    var selectionPreview: String?
    var clipboardPreview: String?
    /// True when AX could not read a selection (Cmd+C fallback deferred to send).
    var axSelectionUnavailable: Bool = false

    var highlightedEntry: PickerEntry {
        guard entries.indices.contains(highlightedIndex) else { return .defaultInput }
        return entries[highlightedIndex]
    }
}

// MARK: - Panel

@MainActor
final class VoicePickerPanel: NSPanel {
    private let state: VoicePickerState
    private let panelWidth: CGFloat = 560
    private let panelHeight: CGFloat = 168
    /// Gap between the picker panel's bottom and the capsule's top.
    private let gapAboveCapsule: CGFloat = 12

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(state: VoicePickerState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let host = NSHostingController(rootView: VoicePickerContent(state: state))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let cv = contentView!
        cv.wantsLayer = true
        cv.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: cv.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }

    /// Position the panel so its bottom sits `gapAboveCapsule` above the
    /// capsule's top edge, horizontally centered on `centerX`.
    func present(aboveCapsuleTop capsuleTopY: CGFloat, centerX: CGFloat) {
        let x = centerX - panelWidth / 2
        let y = capsuleTopY + gapAboveCapsule
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        orderOut(nil)
    }
}

// MARK: - SwiftUI content

private struct VoicePickerContent: View {
    @Bindable var state: VoicePickerState

    private var visibility: (selection: Bool, clipboard: Bool) {
        VoicePickerModel.previewVisibility(for: state.highlightedEntry)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Context preview windows (top).
            HStack(alignment: .top, spacing: 12) {
                if visibility.selection {
                    PreviewWindow(
                        title: String(localized: "Selected text"),
                        body: state.axSelectionUnavailable
                            ? String(localized: "Captured on send")
                            : (state.selectionPreview ?? String(localized: "No selection"))
                    )
                }
                if visibility.clipboard {
                    PreviewWindow(
                        title: String(localized: "Clipboard"),
                        body: state.clipboardPreview ?? String(localized: "Empty")
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(visibility.selection || visibility.clipboard ? 1 : 0)

            // Persona row (bottom, closest to capsule). Horizontal ScrollView so a
            // large persona set is not clipped by the fixed panel width; the
            // highlighted chip is scrolled into view on every cycle.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(state.entries.enumerated()), id: \.offset) { idx, entry in
                            PersonaChip(entry: entry, highlighted: idx == state.highlightedIndex)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: state.highlightedIndex) { _, newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .padding(14)
        .preferredColorScheme(.dark)
    }
}

private struct PreviewWindow: View {
    let title: String
    let message: String

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 250, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct PersonaChip: View {
    let entry: PickerEntry
    let highlighted: Bool

    private var label: String {
        switch entry {
        case .defaultInput: return String(localized: "Default input")
        case .persona(let p): return p.name
        }
    }

    private var icon: String {
        switch entry {
        case .defaultInput: return "mic"
        case .persona(let p): return p.icon
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(highlighted ? Color.white : Color.white.opacity(0.6))
        .background(
            Capsule().fill(highlighted ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.10))
        )
    }
}

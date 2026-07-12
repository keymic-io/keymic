import AppKit
import Observation
import SwiftUI

// MARK: - State

@Observable
@MainActor
final class VoicePickerState {
    var entries: [PickerEntry] = [.defaultInput]
    var highlightedIndex: Int = 0
    /// Trigger-down context snapshot, all read AX-only (no Cmd+C round-trip).
    /// Selected text in the focused element (nil when none / unreadable).
    var selectionPreview: String?
    /// Full text value of the focused input field (nil when unreadable).
    var fieldTextPreview: String?
    /// Up to the 10 most recent clipboard history entries.
    var clipboardHistory: [String] = []
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
    private let panelWidth: CGFloat = 640
    /// Tall enough for the expanded (context-visible) layout. The SwiftUI content
    /// is bottom-anchored, so the persona row stays pinned just above the capsule
    /// and the context windows grow upward into the otherwise-empty (transparent)
    /// top region — the panel height never changes.
    private let panelHeight: CGFloat = 280
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

    private var showsContext: Bool { visibility.selection || visibility.clipboard }

    var body: some View {
        VStack(spacing: 12) {
            // Context preview windows — only present when the highlighted entry
            // declares a context source. Being conditional (not opacity-gated),
            // they reserve NO space when hidden, so the persona row stays tight
            // above the capsule and the windows grow upward when shown.
            if showsContext {
                HStack(alignment: .top, spacing: 12) {
                    if visibility.clipboard {
                        // Left: the 10 most recent clipboard history entries.
                        ClipboardHistoryWindow(items: state.clipboardHistory)
                    }
                    if visibility.selection {
                        // Right: current selection (may be empty) + focused field text.
                        SelectionFieldWindow(
                            selection: state.selectionPreview,
                            selectionUnavailable: state.axSelectionUnavailable,
                            fieldText: state.fieldTextPreview
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Persona row — fixed height, always pinned at the bottom (closest to
            // the capsule). Horizontal ScrollView so a large persona set is not
            // clipped by the fixed panel width; the highlighted chip is scrolled
            // into view on every cycle.
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
            .frame(height: 36)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // Bottom-align the content inside the fixed-height panel so the persona
        // row hugs the capsule and the context windows extend upward.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: showsContext)
        .preferredColorScheme(.dark)
    }
}

/// Shared chrome for a context preview window: title + rounded dark card that
/// fills the available column width and height.
private struct ContextWindowChrome<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Left window: up to the 10 most recent clipboard history entries, numbered.
private struct ClipboardHistoryWindow: View {
    let items: [String]

    var body: some View {
        ContextWindowChrome(title: String(localized: "Clipboard history")) {
            if items.isEmpty {
                Text("Empty")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.prefix(10).enumerated()), id: \.offset) { idx, text in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.4))
                                    .frame(width: 16, alignment: .trailing)
                                Text(text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.white.opacity(0.9))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Right window: the current selection (may be empty) above the focused input
/// field's full text.
private struct SelectionFieldWindow: View {
    let selection: String?
    let selectionUnavailable: Bool
    let fieldText: String?

    private var selectionBody: String {
        if selectionUnavailable { return String(localized: "Captured on send") }
        return selection ?? String(localized: "No selection")
    }

    var body: some View {
        ContextWindowChrome(title: String(localized: "Selected text")) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectionBody)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(selection == nil && !selectionUnavailable ? 0.5 : 0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().overlay(Color.white.opacity(0.12))

                    Text("Input field")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text(fieldText ?? String(localized: "Empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(fieldText == nil ? 0.5 : 0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
        // Opaque fill so chips stay visible on any backdrop (the panel itself is
        // transparent — a light app window would otherwise wash out the chips).
        .foregroundStyle(highlighted ? Color.white : Color.white.opacity(0.85))
        .background(
            Capsule().fill(highlighted ? Color.accentColor.opacity(0.9) : Color.black.opacity(0.72))
        )
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(highlighted ? 0.0 : 0.15), lineWidth: 0.5)
        )
    }
}

import AppKit
import Observation
import SwiftUI

// MARK: - State

@Observable
final class MeetingCaptionState {
    /// Finalized caption rows, oldest→newest. Capped to `maxLines` by the panel.
    var lines: [String] = []
    /// In-progress partial hypothesis shown below the final rows. Empty when idle.
    var partial: String = ""
    /// Non-nil shows a one-line error banner instead of captions.
    var error: String?
}

// MARK: - Panel host

/// Floating, non-activating caption surface for meeting transcription. Mirrors `OverlayPanel`'s
/// borderless `.nonactivatingPanel` style but is user-draggable and remembers its position.
/// M3.1 is single-source (mic), so source labels are hidden.
final class MeetingCaptionPanel: NSPanel, NSWindowDelegate {
    private let state = MeetingCaptionState()
    /// Keep the whole session's final rows so the user can scroll back; bounded so a marathon
    /// meeting can't grow memory without limit. Oldest rows beyond this are dropped.
    private let maxLines = 500

    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 200
    private let margin: CGFloat = 24
    private let minPanelSize = NSSize(width: 280, height: 120)
    private let maxPanelSize = NSSize(width: 1200, height: 1000)

    private static let originXKey = "meetingCaptionOriginX"
    private static let originYKey = "meetingCaptionOriginY"
    private static let sizeWKey = "meetingCaptionWidth"
    private static let sizeHKey = "meetingCaptionHeight"

    // Never steal focus from the meeting app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Drag edges/corners to resize (no title bar); drag the background to move.
        minSize = minPanelSize
        maxSize = maxPanelSize
        delegate = self

        let host = NSHostingController(rootView: MeetingCaptionContent(state: state))
        // Don't let SwiftUI's intrinsic content size drive the window: a long, endpoint-less
        // partial line would otherwise keep growing the panel taller. The panel stays fixed
        // and the content clips internally.
        host.sizingOptions = []
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

    // MARK: - Public API

    func show() {
        state.lines = []
        state.partial = ""
        state.error = nil
        if let size = savedSize() { setContentSize(size) }
        setFrameOrigin(initialOrigin())
        orderFrontRegardless()
    }

    func appendFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.error = nil
        state.lines.append(trimmed)
        if state.lines.count > maxLines {
            state.lines.removeFirst(state.lines.count - maxLines)
        }
        state.partial = ""
    }

    func updatePartial(_ text: String) {
        state.error = nil
        state.partial = text
    }

    func showError(_ message: String) {
        state.error = message
        if !isVisible { setFrameOrigin(initialOrigin()); orderFrontRegardless() }
    }

    func hide() {
        orderOut(nil)
    }

    // MARK: - Position

    private func initialOrigin() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if MeetingPreferences.captionRemembersPosition(),
           let saved = savedOrigin(), screen.contains(saved) {
            return saved
        }
        // Default: bottom-right corner of the visible screen. Use the live frame width so a
        // remembered/resized panel still anchors flush to the right margin.
        return NSPoint(
            x: screen.maxX - frame.width - margin,
            y: screen.minY + margin)
    }

    private func savedOrigin() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.originXKey) != nil,
              d.object(forKey: Self.originYKey) != nil else { return nil }
        return NSPoint(x: d.double(forKey: Self.originXKey), y: d.double(forKey: Self.originYKey))
    }

    /// Remembered content size, clamped to the panel's min/max. nil when none saved or the
    /// remember-position pref is off (size shares that toggle).
    private func savedSize() -> NSSize? {
        guard MeetingPreferences.captionRemembersPosition() else { return nil }
        let d = UserDefaults.standard
        guard d.object(forKey: Self.sizeWKey) != nil,
              d.object(forKey: Self.sizeHKey) != nil else { return nil }
        let w = min(max(d.double(forKey: Self.sizeWKey), minPanelSize.width), maxPanelSize.width)
        let h = min(max(d.double(forKey: Self.sizeHKey), minPanelSize.height), maxPanelSize.height)
        return NSSize(width: w, height: h)
    }

    func windowDidMove(_ notification: Notification) {
        guard MeetingPreferences.captionRemembersPosition() else { return }
        let d = UserDefaults.standard
        d.set(Double(frame.origin.x), forKey: Self.originXKey)
        d.set(Double(frame.origin.y), forKey: Self.originYKey)
    }

    func windowDidResize(_ notification: Notification) {
        guard MeetingPreferences.captionRemembersPosition() else { return }
        let size = contentView?.frame.size ?? frame.size
        let d = UserDefaults.standard
        d.set(Double(size.width), forKey: Self.sizeWKey)
        d.set(Double(size.height), forKey: Self.sizeHKey)
    }
}

// MARK: - SwiftUI content

private struct MeetingCaptionContent: View {
    @Bindable var state: MeetingCaptionState

    /// Stable anchor pinned to the end of the caption list; new content scrolls here.
    private static let bottomAnchor = "caption-bottom"

    var body: some View {
        Group {
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(state.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !state.partial.isEmpty {
                                // Cap the in-progress line: without an endpoint it can grow very
                                // long. Show the most recent tail so the newest words stay visible.
                                Text(state.partial.suffix(120).description)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if state.lines.isEmpty && state.partial.isEmpty {
                                Text(String(localized: "Listening…"))
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(.tertiary)
                            }
                            Color.clear.frame(height: 1).id(Self.bottomAnchor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Pin to newest on a new final row (animated) and as partials stream in. The
                    // user can still scroll up to read history between updates.
                    .onChange(of: state.lines.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                    .onChange(of: state.partial) { _, _ in
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                    .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

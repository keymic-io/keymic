import AppKit
import SwiftUI

/// Borderless floating NSPanel hosting the Selected Text Editor UI.
///
/// Style is similar to `OverlayPanel` — `.nonactivatingPanel` so the originating app keeps focus,
/// `.floating` level, `.canJoinAllSpaces` — but unlike OverlayPanel this one must accept first
/// responder so the instruction text field can receive keystrokes (`canBecomeKey = true`).
@MainActor
final class SelectedTextEditorPanel: NSPanel {
    private weak var controller: SelectedTextEditorController?
    private var hostingController: NSHostingController<SelectedTextEditorView>?
    private var resignKeyDismissWorkItem: DispatchWorkItem?

    private static let defaultSize = NSSize(width: 420, height: 220)
    private static let resignKeyGrace: TimeInterval = 0.2

    init(controller: SelectedTextEditorController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        // .titled is required for canBecomeKey + first-responder text input on a borderless panel;
        // hide the title bar visually via .fullSizeContentView + transparent titlebar.
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

        let view = SelectedTextEditorView(controller: controller)
        let host = NSHostingController(rootView: view)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host.view
        hostingController = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes the panel without applying.
    override func cancelOperation(_ sender: Any?) {
        controller?.close()
    }

    /// Positions the panel near the caret/selection and brings it to front as key.
    /// Falls back to cursor position; clamps to current screen visible frame.
    func presentNearSelection() {
        let target = computeAnchorRect()
        let panelSize = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(target.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Anchor: center under target with 12pt gap. Origin uses bottom-left coords.
        var x = target.midX - panelSize.width / 2
        var y = target.minY - panelSize.height - 12
        if y < visible.minY + 12 {
            // Not enough room below — flip above.
            y = target.maxY + 12
        }
        x = min(max(x, visible.minX + 12), visible.maxX - panelSize.width - 12)
        y = min(max(y, visible.minY + 12), visible.maxY - panelSize.height - 12)
        setFrameOrigin(NSPoint(x: x, y: y))

        orderFrontRegardless()
        makeKey()
    }

    func dismiss() {
        resignKeyDismissWorkItem?.cancel()
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        // Grace window: avoid flicker when the OS animates focus during voice/LLM dispatch.
        resignKeyDismissWorkItem?.cancel()
        let wi = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Don't auto-dismiss while an LLM call is in flight.
            if let isRunning = self.controller?.state.isRunning, isRunning { return }
            self.controller?.close()
        }
        resignKeyDismissWorkItem = wi
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resignKeyGrace, execute: wi)
    }

    override func becomeKey() {
        super.becomeKey()
        resignKeyDismissWorkItem?.cancel()
        resignKeyDismissWorkItem = nil
    }

    // MARK: - Anchor

    /// Best-effort anchor rectangle near the user's selection.
    /// Uses NSEvent.mouseLocation as a reasonable proxy until LOR-17's
    /// boundingRectOfSelection helper ships.
    private func computeAnchorRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        // Treat the cursor as a 1pt anchor; positioning code centers below.
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
    }
}

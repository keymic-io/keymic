import Cocoa

/// Per-screen borderless panel hosting the SelectionOverlayView.
///
/// In the in-place editor model, this panel stays open through the entire flow
/// (drafting → drafted → annotating → confirm/save/cancel). It does NOT close
/// at mouseUp.
final class SelectionOverlayPanel: NSPanel {

    let owningScreen: NSScreen
    let overlayView: SelectionOverlayView

    init(screen: NSScreen) {
        self.owningScreen = screen
        self.overlayView = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Called by controller after capture. Subsequent draws will composite this image.
    func setFrozenFrame(_ image: CGImage?) {
        overlayView.frozenFrame = image
    }

    /// Mark this overlay as drag-owner (true) or non-owner (false).
    func setOwner(_ isOwner: Bool) {
        overlayView.isOwner = isOwner
    }

    func dismiss() {
        orderOut(nil)
    }
}

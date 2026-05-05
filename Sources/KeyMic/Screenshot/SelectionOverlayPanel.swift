import Cocoa

final class SelectionOverlayPanel: NSPanel {
    var onMouseDown: ((NSEvent, NSScreen) -> Void)?
    var onMouseDragged: ((NSEvent, NSScreen) -> Void)?
    var onMouseUp: ((NSEvent, NSScreen) -> Void)?
    var onMouseMoved: ((NSEvent, NSScreen) -> Void)?
    var onCancel: (() -> Void)?  // Esc

    let owningScreen: NSScreen
    private let overlayView: SelectionOverlayView

    init(screen: NSScreen) {
        self.owningScreen = screen
        self.overlayView = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))  // above status bar
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = overlayView
        overlayView.panel = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setSelectionRect(_ rect: NSRect?) {
        overlayView.selectionRect = rect
        overlayView.needsDisplay = true
    }

    func setCursorPosition(_ point: NSPoint?, frozen: Bool) {
        overlayView.cursorPosition = point
        overlayView.frozen = frozen
        overlayView.needsDisplay = true
    }

    func dismiss() {
        orderOut(nil)
    }
}

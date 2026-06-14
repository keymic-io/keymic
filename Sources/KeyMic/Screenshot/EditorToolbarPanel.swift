import Cocoa
import SwiftUI

/// Container view that accepts first-mouse so SwiftUI buttons in a non-key panel
/// receive their click instead of having it swallowed for window activation.
private final class FirstMouseHostContainer: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating panel that hosts the SwiftUI toolbar above the selection overlay.
final class EditorToolbarPanel: NSPanel {
    private let state: EditorState
    private var hostingView: FirstMouseHostingView<EditorToolbarView>!

    init(state: EditorState) {
        self.state = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        ignoresMouseEvents = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        let hosting = FirstMouseHostingView(rootView: EditorToolbarView(state: state))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = FirstMouseHostContainer(frame: NSRect(origin: .zero, size: NSSize(width: 460, height: 80)))
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        hostingView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Compute and apply the panel's frame for a given selection on a given screen.
    /// `selection` is in the overlay view's local coordinates (origin at the panel's
    /// bottom-left); ToolbarPositioner expects global screen coordinates, so offset
    /// by the owning screen's frame origin first (a no-op only on the primary screen).
    func reposition(for selection: NSRect, on screen: NSScreen) {
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: max(360, fittingSize.width), height: max(40, fittingSize.height))
        let globalSelection = selection.offsetBy(dx: screen.frame.origin.x, dy: screen.frame.origin.y)
        let origin = ToolbarPositioner.origin(for: size, selection: globalSelection, screenFrame: screen.frame)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func dismiss() { orderOut(nil) }
}

import AppKit
import ApplicationServices
import SwiftData
import SwiftUI

final class ClipboardPanel: NSPanel {
    private let focus = ClipboardPanelFocus()
    private let hostingController: NSHostingController<AnyView>

    init(
        modelContainer: ModelContainer,
        onPaste: @escaping (ClipboardItem) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onTogglePin: @escaping (UUID) -> Void,
        onVaultPaste: @escaping (VaultItem) -> Void,
        onVaultDelete: @escaping (VaultItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let view = ClipboardHistoryView(
            focus: focus,
            onPaste: onPaste,
            onDelete: onDelete,
            onTogglePin: onTogglePin,
            onVaultPaste: onVaultPaste,
            onVaultDelete: onVaultDelete,
            onDismiss: onDismiss
        )
        .modelContainer(modelContainer)

        hostingController = NSHostingController(rootView: AnyView(view))

        super.init(
            contentRect: ClipboardPanel.initialContentRect(),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        contentView = hostingController.view
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 14
        contentView?.layer?.masksToBounds = true
    }

    var currentTab: PanelTab { focus.currentTab }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    func showAtCursor(initialTab: PanelTab = .clipboard) {
        let size = frame.size
        var anchorPoint: NSPoint = .zero
        var screen: NSScreen?

        let xOffset: CGFloat = 20
        let position = ClipboardPreferences.panelPosition

        if position == .followCursor, let caret = ClipboardPanel.caretScreenRect() {
            // Place panel just below the caret, AppKit coords (bottom-left origin). +118 nudges up.
            anchorPoint = NSPoint(x: caret.minX + xOffset, y: caret.minY - size.height - 6 + 118)
            screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: caret.midX, y: caret.midY), $0.frame, false) })
                ?? NSScreen.main
        } else {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let xCenter = visible.midX - size.width / 2
                anchorPoint = NSPoint(
                    x: position == .followCursor ? xCenter + xOffset : xCenter,
                    y: visible.midY - size.height / 2
                )
            }
        }

        if let visible = screen?.visibleFrame {
            let clampedX = min(max(anchorPoint.x, visible.minX), visible.maxX - size.width)
            let clampedY = min(max(anchorPoint.y, visible.minY), visible.maxY - size.height)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(anchorPoint)
        }

        focus.initialTab = initialTab
        focus.tabRequestID += 1
        makeKeyAndOrderFront(nil)
        focus.requestID += 1
    }

    /// Returns the focused text caret rect in AppKit screen coordinates (bottom-left origin),
    /// or nil if the frontmost element is not a focused text field/area with a known caret.
    private static func caretScreenRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused else { return nil }
        let element = raw as! AXUIElement

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }

        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success, let boundsValue = boundsRef else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.width.isFinite, rect.height.isFinite,
              !(rect.origin.x == 0 && rect.origin.y == 0 && rect.size == .zero) else { return nil }

        // AX returns Quartz screen coords (top-left origin). Convert to AppKit (bottom-left).
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - rect.maxY
        return NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    func switchTab(to tab: PanelTab) {
        focus.initialTab = tab
        focus.tabRequestID += 1
    }

    func dismiss() {
        orderOut(nil)
    }

    func quickPaste(index: Int) {
        focus.quickPasteIndex = index
        focus.quickPasteRequestID += 1
    }

    private static func initialContentRect() -> NSRect {
        let widthRatio: CGFloat = 0.32
        let heightRatio: CGFloat = 0.56
        let minSize = NSSize(width: 480, height: 420)
        let maxSize = NSSize(width: 900, height: 820)

        let visible = AppScreen.main.visibleFrame.size
        let width = min(max(visible.width * widthRatio, minSize.width), maxSize.width)
        let height = min(max(visible.height * heightRatio, minSize.height), maxSize.height)
        return NSRect(x: 0, y: 0, width: width, height: height)
    }
}

import AppKit
import ApplicationServices
import SwiftData
import SwiftUI

final class ClipboardPanel: NSPanel, NSWindowDelegate {
    private let focus = ClipboardPanelFocus()
    private let hostingController: NSHostingController<AnyView>

    init(
        modelContainer: ModelContainer,
        clipboardCacheURL: URL,
        selectionBridge: ClipboardPanelSelectionBridge,
        onPaste: @escaping (ClipboardItem) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onTogglePin: @escaping (UUID) -> Void,
        onVaultPaste: @escaping (VaultItem) -> Void,
        onVaultDelete: @escaping (VaultItem) -> Void,
        onDismiss: @escaping () -> Void,
        onTransformSelected: @escaping () -> Void
    ) {
        let view = ClipboardHistoryView(
            selectionBridge: selectionBridge,
            focus: focus,
            clipboardCacheURL: clipboardCacheURL,
            onPaste: onPaste,
            onDelete: onDelete,
            onTogglePin: onTogglePin,
            onVaultPaste: onVaultPaste,
            onVaultDelete: onVaultDelete,
            onDismiss: onDismiss,
            onTransformSelected: onTransformSelected
        )
        .modelContainer(modelContainer)

        hostingController = NSHostingController(rootView: AnyView(view))

        super.init(
            contentRect: ClipboardPanel.initialContentRect(),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        minSize = NSSize(width: 480, height: 420)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        // Appear/disappear instantly: suppress the default window fade-in/out so the
        // panel shows the moment the hotkey is pressed.
        animationBehavior = .none

        contentView = hostingController.view
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 14
        contentView?.layer?.masksToBounds = true

        delegate = self
    }

    func windowDidResize(_ notification: Notification) {
        ClipboardPreferences.savePanelSize(frame.size)
    }

    var currentTab: PanelTab { focus.currentTab }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if let handledShortcut = handledClipboardShortcut(for: event) {
            handledShortcut()
            return
        }
        // Don't hijack ⌥+number while typing in the Vault search field — the
        // SwiftUI view's text-input guard doesn't run at the panel level.
        let typingInVault = focus.currentTab == .vault && firstResponder is NSText
        if !typingInVault, let quickPasteIndex = quickPasteIndex(for: event) {
            focus.quickPasteIndex = quickPasteIndex
            focus.quickPasteRequestID += 1
            return
        }
        super.sendEvent(event)
    }

    private func handledClipboardShortcut(for event: NSEvent) -> (() -> Void)? {
        guard focus.currentTab == .clipboard, isAltOnlyKeyDown(event) else { return nil }
        if event.keyCode == 0x23 {
            return { [focus] in focus.togglePinRequestID += 1 }
        }
        if let index = pinnedQuickPasteIndex(for: event.keyCode) {
            return { [focus] in
                focus.pinnedQuickPasteIndex = index
                focus.pinnedQuickPasteRequestID += 1
            }
        }
        return nil
    }

    private func quickPasteIndex(for event: NSEvent) -> Int? {
        guard isAltOnlyKeyDown(event) else { return nil }
        switch event.keyCode {
        case 18: return 0
        case 19: return 1
        case 20: return 2
        case 21: return 3
        case 23: return 4
        case 22: return 5
        case 26: return 6
        case 28: return 7
        case 25: return 8
        case 29: return 9
        default: return nil
        }
    }

    private func pinnedQuickPasteIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 0x0C: return 0
        case 0x0D: return 1
        case 0x0E: return 2
        case 0x00: return 3
        case 0x01: return 4
        case 0x02: return 5
        case 0x06: return 6
        case 0x07: return 7
        case 0x08: return 8
        default: return nil
        }
    }

    private func isAltOnlyKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option
    }

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

        let trace = ClipboardOpenTrace.shared
        // The caret lookup is a cross-process Accessibility query — a prime suspect for
        // per-open lag in some apps; measure it on its own line.
        let caret: NSRect? = position == .followCursor ? ClipboardPanel.caretScreenRect() : nil
        trace.mark("caretScreenRect (position=\(position))")

        if position == .followCursor, let caret {
            // Place panel just below the caret, AppKit coords (bottom-left origin). +118 nudges up.
            anchorPoint = NSPoint(x: caret.minX + xOffset, y: caret.minY - size.height - 6 + 118)
            screen =
                NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: caret.midX, y: caret.midY), $0.frame, false) })
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
        trace.mark("before makeKeyAndOrderFront")
        makeKeyAndOrderFront(nil)
        trace.mark("after makeKeyAndOrderFront")
        focus.requestID += 1
    }

    /// Returns the focused text caret rect in AppKit screen coordinates (bottom-left origin),
    /// or nil if the frontmost element is not a focused text field/area with a known caret.
    private static func caretScreenRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let raw = focused,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: guarded by CFGetTypeID. AXUIElement is a CF type which Swift's `as?` does not bridge.
        let element = raw as! AXUIElement

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rangeValue = rangeRef
        else { return nil }

        var boundsRef: AnyObject?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsRef
            ) == .success, let boundsValue = boundsRef,
            CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        // Safe: guarded by CFGetTypeID above.
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
            rect.width.isFinite, rect.height.isFinite,
            !(rect.origin.x == 0 && rect.origin.y == 0 && rect.size == .zero)
        else { return nil }

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
        let widthRatio: CGFloat = 0.352
        let heightRatio: CGFloat = 0.56
        let minSize = NSSize(width: 480, height: 420)
        let maxSize = NSSize(width: 990, height: 820)

        let visible = AppScreen.main.visibleFrame.size

        if let saved = ClipboardPreferences.panelSize {
            let w = min(max(saved.width, minSize.width), max(visible.width, minSize.width))
            let h = min(max(saved.height, minSize.height), max(visible.height, minSize.height))
            return NSRect(x: 0, y: 0, width: w, height: h)
        }

        let width = min(max(visible.width * widthRatio, minSize.width), maxSize.width)
        let height = min(max(visible.height * heightRatio, minSize.height), maxSize.height)
        return NSRect(x: 0, y: 0, width: width, height: height)
    }
}

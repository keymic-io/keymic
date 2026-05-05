import Cocoa
import SwiftUI
import Combine

// MARK: - CenteringClipView

/// An NSClipView subclass that recenters the document view when it is smaller than the clip bounds.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        if rect.width > docView.frame.width {
            rect.origin.x = (docView.frame.width - rect.width) / 2.0
        }
        if rect.height > docView.frame.height {
            rect.origin.y = (docView.frame.height - rect.height) / 2.0
        }
        return rect
    }
}

// MARK: - EditorWindowController

final class EditorWindowController: NSWindowController, NSWindowDelegate, AnnotationCanvasDelegate {

    // MARK: Owned components

    let canvas: AnnotationCanvasView
    let state: EditorState
    let exporter = ScreenshotExporter()
    var onClose: (() -> Void)?

    var topBarHosting: NSHostingView<EditorTopBarView>!
    var sidebarHosting: NSHostingView<EditorToolSidebarView>!
    var scrollView: NSScrollView!

    /// Mirrors canvas.hasBeenSaved; also writable so callers can reset it.
    var hasBeenSaved: Bool {
        get { canvas.hasBeenSaved }
        set { canvas.hasBeenSaved = newValue }
    }

    // MARK: Private

    private var cancellables = Set<AnyCancellable>()
    private var escMonitor: Any?

    // Layout constants
    private let sidebarWidth: CGFloat = 96
    private let topBarHeight: CGFloat = 44

    // MARK: Init

    init(image: NSImage) {
        canvas = AnnotationCanvasView(image: image)
        state  = EditorState()

        // Compute initial window content size
        let imageSize = image.size
        let idealContentSize = NSSize(
            width:  imageSize.width  + sidebarWidth,
            height: imageSize.height + topBarHeight
        )

        // Clamp to 90% of main screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = screenFrame.width  * 0.9
        let maxH = screenFrame.height * 0.9
        let clampedW = min(idealContentSize.width,  maxW)
        let clampedH = min(idealContentSize.height, maxH)
        let minW: CGFloat = 400
        let minH: CGFloat = 300
        let contentW = max(minW, clampedW)
        let contentH = max(minH, clampedH)

        // Center on screen
        let originX = screenFrame.midX - contentW / 2
        let originY = screenFrame.midY - contentH / 2
        let contentFrame = NSRect(x: originX, y: originY, width: contentW, height: contentH)

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let win = NSWindow(
            contentRect: contentFrame,
            styleMask:   styleMask,
            backing:     .buffered,
            defer:       false
        )
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: minW + sidebarWidth, height: minH + topBarHeight)

        // Title with timestamp
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        win.title = "Screenshot — \(fmt.string(from: Date()))"

        super.init(window: win)

        win.delegate = self
        canvas.delegate = self

        buildLayout()
        bindStateToCanvas()
        wireCallbacks()
        installEscMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        // --- Top bar ---
        topBarHosting = NSHostingView(rootView: EditorTopBarView(state: state))
        topBarHosting.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBarHosting)

        // --- Sidebar ---
        sidebarHosting = NSHostingView(rootView: EditorToolSidebarView(state: state))
        sidebarHosting.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sidebarHosting)

        // --- ScrollView with centering clip ---
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller   = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder
        scrollView.backgroundColor       = .darkGray

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        canvas.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvas
        contentView.addSubview(scrollView)

        // Auto Layout
        NSLayoutConstraint.activate([
            // Top bar: full width at top, fixed height
            topBarHosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            topBarHosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBarHosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBarHosting.heightAnchor.constraint(equalToConstant: topBarHeight),

            // Sidebar: fixed width, from below top bar to bottom
            sidebarHosting.topAnchor.constraint(equalTo: topBarHosting.bottomAnchor),
            sidebarHosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarHosting.widthAnchor.constraint(equalToConstant: sidebarWidth),
            sidebarHosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // ScrollView: fills the remaining space
            scrollView.topAnchor.constraint(equalTo: topBarHosting.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebarHosting.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - State ↔ Canvas Binding

    private func bindStateToCanvas() {
        state.$selectedTool
            .sink { [weak self] tool in self?.canvas.selectedTool = tool }
            .store(in: &cancellables)

        state.$selectedColor
            .sink { [weak self] color in self?.canvas.currentColor = NSColor(color) }
            .store(in: &cancellables)

        state.$lineWidth
            .sink { [weak self] width in self?.canvas.currentLineWidth = width }
            .store(in: &cancellables)

        state.$fontSize
            .sink { [weak self] size in self?.canvas.currentFontSize = size }
            .store(in: &cancellables)

        state.$dropShadowEnabled
            .sink { [weak self] enabled in self?.canvas.currentDropShadow = enabled }
            .store(in: &cancellables)
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        state.undoAction = { [weak self] in
            self?.canvas.canvasUndoManager.undo()
            self?.refreshUndoState()
        }
        state.redoAction = { [weak self] in
            self?.canvas.canvasUndoManager.redo()
            self?.refreshUndoState()
        }
        state.clearAction  = { [weak self] in self?.canvas.clearAll() }
        state.copyAction   = { [weak self] in self?.performCopy() }
        state.saveAction   = { [weak self] in self?.performSave() }
        state.shareAction  = { [weak self] view, rect in self?.performShare(from: view, rect: rect) }
    }

    // MARK: - Esc Key Monitor

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            if event.keyCode == 53 { // Esc
                self.window?.performClose(nil)
                return nil
            }
            return event
        }
    }

    // MARK: - Export Actions

    private func renderedImage() -> NSImage {
        guard let cg = canvas.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return canvas.image
        }
        return AnnotationRenderer.render(base: cg, annotations: canvas.annotations, pointSize: canvas.image.size)
    }

    private func performCopy() {
        exporter.copyToPasteboard(renderedImage())
        canvas.hasBeenSaved = true
        window?.close()
    }

    private func performSave() {
        exporter.saveWithFolderPicker(renderedImage(), from: window) { [weak self] ok in
            if ok {
                self?.canvas.hasBeenSaved = true
                self?.window?.close()
            }
        }
    }

    private func performShare(from view: NSView, rect: NSRect) {
        exporter.showShareSheet(renderedImage(), from: view, relativeTo: rect)
    }

    // MARK: - Undo State

    private func refreshUndoState() {
        state.canUndo = canvas.canvasUndoManager.canUndo
        state.canRedo = canvas.canvasUndoManager.canRedo
    }

    // MARK: - Public API

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if canvas.hasBeenSaved || canvas.annotations.isEmpty { return true }

        let alert = NSAlert()
        alert.messageText     = "Close without saving?"
        alert.informativeText = "Your annotations will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:   // Save
            performSave()
            return false  // performSave closes on success
        case .alertSecondButtonReturn:  // Copy to Clipboard
            performCopy()
            return false
        case .alertThirdButtonReturn:   // Discard
            return true
        default:                        // Cancel
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Remove local event monitor
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        // Cancel Combine subscriptions
        cancellables.removeAll()
        onClose?()
    }

    // MARK: - AnnotationCanvasDelegate

    func canvasDidUpdateUndoState(_ canvas: AnnotationCanvasView) {
        refreshUndoState()
    }

    func canvasDidChangeSelection(_ canvas: AnnotationCanvasView) {
        // selectedAnnotationID is private; infer selection from the delegate firing after
        // a tool-level interaction. We derive hasSelection by checking if the canvas is in
        // the .select tool and received a change-selection callback — the canvas only fires
        // this when selectedAnnotationID changes (deselect also fires it). We store selection
        // state here using a secondary heuristic: we attempt to hit-test nothing… but since
        // we have no public accessor we use the annotation count and rely on clearAll /
        // deleteSelected also calling this delegate. For v1, we defer this to canvasDidMutate
        // and always set hasSelection = false on deselect calls originating from tool changes
        // (the canvas resets selectedAnnotationID in selectedTool.didSet and calls this delegate).
        // A simple and correct workaround: track via a flag toggled by canvasDidMutate.
        // The task spec says: if no clean way, defer hasSelection updates. We implement a
        // best-effort approach: set hasSelection = true when tool == .select AND annotations
        // are non-empty (conservative), reset on tool change via state binding.
        //
        // NOTE: To fix this properly, AnnotationCanvasView should expose a computed
        // `var hasSelection: Bool { selectedAnnotationID != nil }` — tracked in concerns.
        state.hasSelection = (canvas.selectedTool == .select && !canvas.annotations.isEmpty
                              && canvas.selectedTool == .select)
    }

    func canvasDidMutate(_ canvas: AnnotationCanvasView) {
        canvas.hasBeenSaved = false
    }
}

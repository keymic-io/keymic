import Cocoa
import VisionKit

protocol SelectionOverlayViewDelegate: AnyObject {
    func overlayDidEnterDrafted(_ view: SelectionOverlayView)
    func overlayDidUpdateSelection(_ view: SelectionOverlayView)
    func overlayDidUpdateState(_ view: SelectionOverlayView)
    func overlayDidCancel(_ view: SelectionOverlayView)
    func overlayDidConfirm(_ view: SelectionOverlayView)
    func overlayDidSave(_ view: SelectionOverlayView)
}

/// In-place WeChat-style overlay editor.
final class SelectionOverlayView: NSView, NSTextFieldDelegate {

    weak var delegate: SelectionOverlayViewDelegate?
    let state = ScreenshotOverlayState()
    let canvasUndoManager = UndoManager()

    var frozenFrame: CGImage? { didSet { needsDisplay = true } }
    var isOwner: Bool = true { didSet { needsDisplay = true; updateCursor() } }

    var selection: NSRect { state.selection }
    var annotations: [Annotation] { state.annotations }

    func updateColor(_ color: NSColor) { state.currentColor = color }
    func updateLineWidth(_ w: CGFloat) { state.currentLineWidth = w }
    func updateFontSize(_ s: CGFloat) { state.currentFontSize = s }
    func updateDropShadow(_ on: Bool) { state.currentDropShadow = on }
    func updateTool(_ tool: AnnotationTool) {
        cancelTextEditing()
        state.setSelectedTool(tool)
        if tool == .ocr {
            installOCROverlay()
        } else {
            removeOCROverlay()
        }
        updateCursor()
        needsDisplay = true
        delegate?.overlayDidUpdateState(self)
    }

    private var currentDraftAnnotation: Annotation?
    private var activeTextField: NSTextField?
    private var highlightedWindowRect: NSRect?  // view-local rect of detected window in idle phase
    private var pendingClickWindow: NSRect?     // captured at mouseDown; consumed on mouseUp if user didn't drag
    private var ocrOverlay: ImageAnalysisOverlayView?
    private var ocrAnalyzeTask: Task<Void, Never>?
    private let ocrAnalyzer = ImageAnalyzer()
    private(set) var isOCRAnalyzing = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var undoManager: UndoManager? { canvasUndoManager }

    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        state.screenBounds = NSRect(origin: .zero, size: frame.size)
        rebuildTrackingArea()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        state.screenBounds = NSRect(origin: .zero, size: newSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let frame = frozenFrame {
            ctx.draw(frame, in: bounds)
        }

        let maskAlpha: CGFloat = isOwner ? 0.25 : 0.45
        NSColor.black.withAlphaComponent(maskAlpha).setFill()
        bounds.fill()

        if state.selection != .zero, isOwner {
            drawCutoutAndAnnotations(ctx: ctx)
            drawSelectionChrome()
            switch state.phase {
            case .drafted, .resizing: drawHandles()
            default: break
            }
            drawSelectedAnnotationChrome(ctx: ctx)
            drawDimensionsHUD()
        } else if isOwner && state.phase == .idle {
            if let winRect = highlightedWindowRect {
                drawWindowHighlight(winRect)
            }
            drawHint()
        }
    }

    private func drawCutoutAndAnnotations(ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let sel = state.selection
        if let frame = frozenFrame {
            let scaleX = CGFloat(frame.width) / bounds.width
            let scaleY = CGFloat(frame.height) / bounds.height
            let pxRect = CGRect(
                x: sel.origin.x * scaleX,
                y: (bounds.height - sel.maxY) * scaleY,
                width: sel.width * scaleX,
                height: sel.height * scaleY
            )
            if let cropped = frame.cropping(to: pxRect) {
                ctx.draw(cropped, in: sel)
            }
        }

        ctx.clip(to: sel)
        ctx.translateBy(x: sel.origin.x, y: sel.origin.y)

        for ann in state.annotations {
            switch ann.kind {
            case .mosaic, .blur: drawEffectAnnotation(ann, ctx: ctx, selection: sel)
            case .rect: drawRectAnnotation(ann, ctx: ctx)
            case .ellipse: drawEllipseAnnotation(ann, ctx: ctx)
            case .arrow: drawArrowAnnotation(ann, ctx: ctx)
            case .text: drawTextAnnotation(ann)
            case .highlight: drawHighlightAnnotation(ann, ctx: ctx)
            case .pen: drawPenAnnotation(ann, ctx: ctx)
            case .select, .ocr: continue
            }
        }
        if let draft = currentDraftAnnotation {
            switch draft.kind {
            case .rect: drawRectAnnotation(draft, ctx: ctx)
            case .ellipse: drawEllipseAnnotation(draft, ctx: ctx)
            case .arrow: drawArrowAnnotation(draft, ctx: ctx)
            case .highlight: drawHighlightAnnotation(draft, ctx: ctx)
            case .mosaic, .blur: drawEffectAnnotation(draft, ctx: ctx, selection: sel)
            case .pen: drawPenAnnotation(draft, ctx: ctx)
            default: break
            }
        }
    }

    private func drawEffectAnnotation(_ ann: Annotation, ctx: CGContext, selection: NSRect) {
        guard let frame = frozenFrame else { return }
        let localRect = ann.rect
        let screenRect = NSRect(
            x: localRect.origin.x + selection.origin.x,
            y: localRect.origin.y + selection.origin.y,
            width: localRect.width,
            height: localRect.height
        )
        let scaleX = CGFloat(frame.width) / bounds.width
        let scaleY = CGFloat(frame.height) / bounds.height
        let pxRect = CGRect(
            x: screenRect.origin.x * scaleX,
            y: (bounds.height - screenRect.maxY) * scaleY,
            width: screenRect.width * scaleX,
            height: screenRect.height * scaleY
        )
        guard pxRect.width >= 1, pxRect.height >= 1, let crop = frame.cropping(to: pxRect) else { return }
        let effect: CGImage?
        switch ann.kind {
        case .mosaic: effect = Pixelator.mosaic(image: crop, scale: 12)
        case .blur:   effect = Pixelator.blur(image: crop, radius: 10)
        default: return
        }
        guard let result = effect else { return }
        ctx.draw(result, in: localRect)
    }

    private func drawRectAnnotation(_ ann: Annotation, ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        if ann.hasDropShadow {
            ctx.setShadow(offset: CGSize(width: 2, height: -2), blur: 4,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        ctx.stroke(ann.rect)
    }

    private func drawEllipseAnnotation(_ ann: Annotation, ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.strokeEllipse(in: ann.rect)
    }

    private func drawArrowAnnotation(_ ann: Annotation, ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: ann.startPoint)
        ctx.addLine(to: ann.endPoint)
        ctx.strokePath()
        let angle = atan2(ann.endPoint.y - ann.startPoint.y, ann.endPoint.x - ann.startPoint.x)
        let headLength = max(ann.lineWidth * 4, 12)
        let headAngle = CGFloat.pi / 6
        let tip1 = CGPoint(x: ann.endPoint.x - headLength * cos(angle - headAngle),
                           y: ann.endPoint.y - headLength * sin(angle - headAngle))
        let tip2 = CGPoint(x: ann.endPoint.x - headLength * cos(angle + headAngle),
                           y: ann.endPoint.y - headLength * sin(angle + headAngle))
        ctx.setFillColor(ann.color.cgColor)
        ctx.move(to: ann.endPoint); ctx.addLine(to: tip1); ctx.addLine(to: tip2); ctx.closePath()
        ctx.fillPath()
    }

    private func drawPenAnnotation(_ ann: Annotation, ctx: CGContext) {
        guard ann.points.count >= 2 else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        AnnotationRenderer.strokeSmooth(ann.points, in: ctx)
    }

    private func drawWindowHighlight(_ rect: NSRect) {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
        let border = NSBezierPath(roundedRect: clipped.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        border.lineWidth = 2.5
        NSColor.systemGreen.setStroke()
        border.stroke()
    }

    private func drawTextAnnotation(_ ann: Annotation) {
        guard !ann.text.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: ann.color,
            .backgroundColor: NSColor.white.withAlphaComponent(0.75),
        ]
        if let font = SelectionOverlayView.safeSystemFont(ofSize: ann.fontSize, weight: .semibold) {
            attrs[.font] = font
        }
        NSAttributedString(string: ann.text, attributes: attrs).draw(at: ann.startPoint)
    }

    private static func safeSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        if let f = NSFont.systemFont(ofSize: size, weight: weight) as NSFont? { return f }
        if let f = NSFont.systemFont(ofSize: size) as NSFont? { return f }
        return NSFont(name: "Helvetica", size: size)
    }

    private static func safeMonospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        if let f = NSFont.monospacedSystemFont(ofSize: size, weight: weight) as NSFont? { return f }
        if let f = NSFont.userFixedPitchFont(ofSize: size) { return f }
        return safeSystemFont(ofSize: size, weight: weight)
    }

    private func drawHighlightAnnotation(_ ann: Annotation, ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setFillColor(ann.color.withAlphaComponent(0.35).cgColor)
        ctx.fill(ann.rect)
    }

    private func drawSelectionChrome() {
        let sel = state.selection
        NSColor.white.setStroke()
        let outer = NSBezierPath(rect: sel)
        outer.lineWidth = 1.5
        outer.stroke()
        NSColor.black.withAlphaComponent(0.7).setStroke()
        let inner = NSBezierPath(rect: sel.insetBy(dx: 0.75, dy: 0.75))
        inner.lineWidth = 0.5
        inner.setLineDash([4, 4], count: 2, phase: 0)
        inner.stroke()
    }

    private func drawHandles() {
        let sel = state.selection
        for h in ResizeHandle.allCases {
            let r = h.visualRect(in: sel)
            NSColor.white.setFill(); r.fill()
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 1; p.stroke()
        }
    }

    private func drawSelectedAnnotationChrome(ctx: CGContext) {
        guard let id = state.selectedAnnotationID,
              let ann = state.annotations.first(where: { $0.id == id }) else { return }
        let sel = state.selection
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.translateBy(x: sel.origin.x, y: sel.origin.y)
        let outline = NSBezierPath(rect: ann.rect.insetBy(dx: -4, dy: -4))
        outline.lineWidth = 1; outline.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.systemBlue.setStroke()
        outline.stroke()
    }

    private func drawDimensionsHUD() {
        let sel = state.selection
        guard sel.width >= 1, sel.height >= 1 else { return }
        let str = String(format: "%d × %d", Int(sel.width), Int(sel.height))
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
        ]
        if let font = SelectionOverlayView.safeMonospacedFont(ofSize: 11, weight: .medium) {
            attrs[.font] = font
        }
        let textSize = (str as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 4
        var hudRect = NSRect(
            x: sel.minX,
            y: sel.minY - textSize.height - pad * 2 - 4,
            width: textSize.width + pad * 2,
            height: textSize.height + pad * 2
        )
        if hudRect.minY < bounds.minY { hudRect.origin.y = sel.maxY + 4 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: hudRect, xRadius: 3, yRadius: 3).fill()
        (str as NSString).draw(at: NSPoint(x: hudRect.minX + pad, y: hudRect.minY + pad), withAttributes: attrs)
    }

    private func drawHint() {
        let hint = String(localized: "Click and drag to select a region  •  Press Esc to cancel")
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        if let font = SelectionOverlayView.safeSystemFont(ofSize: 13, weight: .regular) {
            attrs[.font] = font
        }
        let size = (hint as NSString).size(withAttributes: attrs)
        (hint as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        guard isOwner else { return }
        if state.selectedTool == .ocr { return }
        let p = convert(event.locationInWindow, from: nil)
        cancelTextEditing()
        switch state.phase {
        case .idle:
            // Remember any detected window so a clean click (no drag) can commit it on mouseUp.
            pendingClickWindow = highlightedWindowRect
            highlightedWindowRect = nil
            state.beginDrafting(at: p)
            needsDisplay = true
        case .drafted:
            handleDraftedMouseDown(at: p, click: event.clickCount)
        default: break
        }
    }

    private func handleDraftedMouseDown(at p: NSPoint, click: Int) {
        if click == 2, state.selection.contains(p),
           ResizeHandle.handle(at: p, in: state.selection) == nil {
            delegate?.overlayDidConfirm(self)
            return
        }
        let target = state.target(for: p)
        switch target {
        case .handle(let h):
            snapshotIfNeeded()
            state.beginResizing(handle: h)
        case .selectionInterior:
            if state.selectedTool.isDrawingTool {
                beginAnnotating(at: p)
            } else {
                snapshotIfNeeded()
                state.beginMoving(at: p)
            }
        case .annotation(let id):
            state.selectAnnotation(id)
            needsDisplay = true
            delegate?.overlayDidUpdateState(self)
        case .nothing:
            state.selectAnnotation(nil)
            needsDisplay = true
        }
    }

    private func beginAnnotating(at p: NSPoint) {
        let sel = state.selection
        let local = NSPoint(x: p.x - sel.minX, y: p.y - sel.minY)
        if state.selectedTool == .text {
            spawnTextField(atScreenPoint: p)
            return
        }
        // Note: undo snapshot is registered on commit (mouseUp), not here.
        // Registering on draft-start and rolling back on a too-small draft would
        // require popping a single entry off the undo stack, which UndoManager
        // doesn't expose; previous attempts used removeAllActions(withTarget:),
        // which wiped the user's earlier annotation history.
        let ann = Annotation(
            kind: state.selectedTool,
            startPoint: local,
            endPoint: local,
            color: state.currentColor,
            lineWidth: state.currentLineWidth,
            text: "",
            fontSize: state.currentFontSize,
            hasDropShadow: state.currentDropShadow
        )
        currentDraftAnnotation = ann
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isOwner else { return }
        if state.selectedTool == .ocr { return }
        let p = convert(event.locationInWindow, from: nil)
        switch state.phase {
        case .drafting:
            state.updateDrafting(to: p)
            delegate?.overlayDidUpdateSelection(self)
            needsDisplay = true
        case .resizing:
            state.updateResizing(to: p)
            delegate?.overlayDidUpdateSelection(self)
            needsDisplay = true
        case .moving:
            state.updateMoving(to: p)
            delegate?.overlayDidUpdateSelection(self)
            needsDisplay = true
        default:
            if let draft = currentDraftAnnotation {
                let sel = state.selection
                let local = NSPoint(x: p.x - sel.minX, y: p.y - sel.minY)
                if draft.kind == .pen {
                    draft.points.append(local)
                } else {
                    draft.endPoint = local
                }
                needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isOwner else { return }
        if state.selectedTool == .ocr { return }
        switch state.phase {
        case .drafting:
            // Clean click on a detected window (no real drag) → use the window rect.
            if let winRect = pendingClickWindow,
               state.selection.width < 5, state.selection.height < 5 {
                pendingClickWindow = nil
                state.commitWindowSelection(winRect.intersection(bounds))
                delegate?.overlayDidEnterDrafted(self)
                needsDisplay = true
                return
            }
            pendingClickWindow = nil
            if state.finishDrafting() {
                delegate?.overlayDidEnterDrafted(self)
            } else {
                delegate?.overlayDidCancel(self)
            }
            needsDisplay = true
        case .resizing, .moving:
            state.finishGesture()
            delegate?.overlayDidUpdateSelection(self)
            needsDisplay = true
        default:
            if let draft = currentDraftAnnotation {
                if draft.hasMinimumSize || draft.kind == .arrow {
                    snapshotIfNeeded()
                    state.addAnnotation(draft)
                    delegate?.overlayDidUpdateState(self)
                }
                // Discard too-small draft: simply drop currentDraftAnnotation.
                // No undo entry was registered on draft-start, so nothing to roll back.
                currentDraftAnnotation = nil
                needsDisplay = true
            }
        }
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isOwner else { return }
        if state.phase == .idle {
            let viewPt = convert(event.locationInWindow, from: nil)
            let panelOrigin = window?.frame.origin ?? .zero
            let screenPt = NSPoint(x: panelOrigin.x + viewPt.x, y: panelOrigin.y + viewPt.y)
            let found = WindowFinder.windowRect(atScreenPoint: screenPt)
            let viewRect = found.map {
                NSRect(x: $0.minX - panelOrigin.x, y: $0.minY - panelOrigin.y,
                       width: $0.width, height: $0.height)
            }
            if viewRect != highlightedWindowRect {
                highlightedWindowRect = viewRect
                needsDisplay = true
            }
        } else if highlightedWindowRect != nil {
            highlightedWindowRect = nil
            needsDisplay = true
        }
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard isOwner else { return }
        if highlightedWindowRect != nil {
            highlightedWindowRect = nil
            needsDisplay = true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            delegate?.overlayDidCancel(self); return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / numpad enter
            if state.phase == .drafted {
                delegate?.overlayDidConfirm(self); return
            }
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward delete
            if state.selectedAnnotationID != nil {
                snapshotIfNeeded()
                state.removeSelectedAnnotation()
                delegate?.overlayDidUpdateState(self)
                needsDisplay = true
                return
            }
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) {
                canvasUndoManager.redo()
            } else {
                canvasUndoManager.undo()
            }
            delegate?.overlayDidUpdateState(self)
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Cursor

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        guard isOwner else { NSCursor.arrow.set(); return }
        let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? .zero
        let p = convert(mouseInWindow, from: nil)
        if state.selectedTool == .ocr {
            if !state.selection.contains(p) {
                NSCursor.arrow.set()
            }
            return
        }
        switch state.phase {
        case .idle, .drafting:
            NSCursor.crosshair.set()
        case .drafted, .resizing, .moving:
            if let h = ResizeHandle.handle(at: p, in: state.selection) {
                h.cursor.set()
            } else if state.selection.contains(p) {
                // Drawing tool armed → normal arrow (user will drag to draw, not move).
                // Select tool → openHand to hint that the selection is draggable.
                if state.selectedTool.isDrawingTool {
                    NSCursor.arrow.set()
                } else {
                    NSCursor.openHand.set()
                }
            } else {
                NSCursor.arrow.set()
            }
        case .annotating:
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Text editing

    private func spawnTextField(atScreenPoint p: NSPoint) {
        let field = NSTextField()
        field.delegate = self
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = state.currentColor
        field.font = NSFont.systemFont(ofSize: state.currentFontSize, weight: .semibold)
        field.frame = NSRect(x: p.x, y: p.y - 8, width: 200, height: state.currentFontSize + 8)
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
    }

    private func cancelTextEditing() {
        activeTextField?.removeFromSuperview()
        activeTextField = nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = activeTextField else { return }
        let text = field.stringValue
        let sel = state.selection
        let local = NSPoint(x: field.frame.minX - sel.minX, y: field.frame.minY - sel.minY + 8)
        if !text.isEmpty {
            snapshotIfNeeded()
            let ann = Annotation(
                kind: .text,
                startPoint: local,
                color: state.currentColor,
                text: text,
                fontSize: state.currentFontSize
            )
            state.addAnnotation(ann)
            delegate?.overlayDidUpdateState(self)
            needsDisplay = true
        }
        cancelTextEditing()
    }

    // MARK: - Undo

    private func snapshotIfNeeded() {
        let snapshot = state.annotations.compactMap { $0.copy() as? Annotation }
        canvasUndoManager.registerUndo(withTarget: self) { target in
            target.restoreSnapshot(snapshot)
        }
    }

    private func restoreSnapshot(_ snapshot: [Annotation]) {
        let current = state.annotations.compactMap { $0.copy() as? Annotation }
        canvasUndoManager.registerUndo(withTarget: self) { target in
            target.restoreSnapshot(current)
        }
        state.clearAnnotations()
        for a in snapshot { state.addAnnotation(a) }
        delegate?.overlayDidUpdateState(self)
        needsDisplay = true
    }

    // MARK: - OCR (VisionKit Live Text)

    private func installOCROverlay() {
        removeOCROverlay()
        guard let frame = frozenFrame else { return }
        let sel = state.selection
        guard sel.width > 1, sel.height > 1 else { return }

        let scaleX = CGFloat(frame.width) / bounds.width
        let scaleY = CGFloat(frame.height) / bounds.height
        let pxRect = CGRect(
            x: sel.origin.x * scaleX,
            y: (bounds.height - sel.maxY) * scaleY,
            width: sel.width * scaleX,
            height: sel.height * scaleY
        )
        guard let cropped = frame.cropping(to: pxRect) else { return }

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = .textSelection
        overlay.frame = sel
        overlay.autoresizingMask = []
        addSubview(overlay)
        ocrOverlay = overlay

        let config = ImageAnalyzer.Configuration([.text])
        isOCRAnalyzing = true
        delegate?.overlayDidUpdateState(self)

        ocrAnalyzeTask = Task { [weak self, weak overlay, analyzer = ocrAnalyzer] in
            defer {
                // Capture cancellation status synchronously: a newer OCR task
                // would have called .cancel() on this one before replacing it,
                // and we must not clear `isOCRAnalyzing` for the live task.
                let wasCancelled = Task.isCancelled
                Task { @MainActor [weak self] in
                    guard let self, !wasCancelled else { return }
                    self.isOCRAnalyzing = false
                    self.delegate?.overlayDidUpdateState(self)
                }
            }
            do {
                let analysis = try await analyzer.analyze(
                    cropped,
                    orientation: .up,
                    configuration: config
                )
                await MainActor.run {
                    guard let overlay = overlay else { return }
                    overlay.analysis = analysis
                    self?.window?.makeFirstResponder(overlay)
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("[Screenshot] OCR analyze failed: \(error)")
            }
        }
    }

    private func removeOCROverlay() {
        ocrAnalyzeTask?.cancel()
        ocrAnalyzeTask = nil
        isOCRAnalyzing = false
        if let overlay = ocrOverlay {
            if let firstResp = window?.firstResponder as? NSView, firstResp.isDescendant(of: overlay) || firstResp === overlay {
                window?.makeFirstResponder(self)
            }
            overlay.removeFromSuperview()
        }
        ocrOverlay = nil
    }
}

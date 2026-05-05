import Cocoa

// MARK: - Delegate

protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidUpdateUndoState(_ canvas: AnnotationCanvasView)
    func canvasDidChangeSelection(_ canvas: AnnotationCanvasView)
    func canvasDidMutate(_ canvas: AnnotationCanvasView)
}

// MARK: - Canvas interaction state

private enum CanvasState {
    case idle
    case drafting
    case textEditing
    case moving(id: UUID, dragOrigin: CGPoint, originalStart: CGPoint, originalEnd: CGPoint)
    case resizing(id: UUID, oppositeCorner: CGPoint)
}

// MARK: - AnnotationCanvasView

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {

    // MARK: Public API

    var image: NSImage {
        didSet { deriveBaseCGImage(); needsDisplay = true }
    }
    var baseCGImage: CGImage?

    var annotations: [Annotation] = [] {
        didSet { needsDisplay = true }
    }

    var selectedTool: AnnotationTool = .select {
        didSet {
            selectedAnnotationID = nil
            needsDisplay = true
            cancelTextEditingIfNeeded()
            updateCursor()
            delegate?.canvasDidChangeSelection(self)
        }
    }

    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 3
    var currentFontSize: CGFloat = 18
    var currentDropShadow: Bool = false
    var hasBeenSaved: Bool = false
    weak var delegate: AnnotationCanvasDelegate?

    let canvasUndoManager = UndoManager()
    override var undoManager: UndoManager? { canvasUndoManager }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Private state

    private var canvasState: CanvasState = .idle
    private var currentAnnotation: Annotation?
    private var selectedAnnotationID: UUID?
    private var didPushUndoForSelectionInteraction = false
    private var inlineTextField: NSTextField?
    private var inlineTextFieldOrigin: CGPoint = .zero

    // MARK: Hit-test constants

    private let annotationHitPadding: CGFloat = 6
    private let handleRadius: CGFloat = 5
    private let handleSize: CGFloat = 10

    // MARK: Init

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        deriveBaseCGImage()
        wantsLayer = true
        setupTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Base image

    private func deriveBaseCGImage() {
        var rect = NSRect(origin: .zero, size: image.size)
        baseCGImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Tracking area

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.activeInActiveApp, .mouseMoved,
                                               .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    // MARK: - First responder

    override func becomeFirstResponder() -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw base image
        image.draw(in: bounds)

        // 2. Draw committed annotations
        for ann in annotations {
            drawAnnotation(ann, context: ctx)
        }

        // 3. Draw in-progress draft
        if let draft = currentAnnotation {
            drawAnnotation(draft, context: ctx)
        }

        // 4. Draw selection chrome
        if let selID = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == selID }) {
            drawSelectionChrome(for: ann, context: ctx)
        }
    }

    // MARK: Drawing helpers

    private func drawAnnotation(_ ann: Annotation, context ctx: CGContext) {
        switch ann.kind {
        case .select: break
        case .rect:     drawRect(ann, in: ctx)
        case .ellipse:  drawEllipse(ann, in: ctx)
        case .arrow:    drawArrow(ann, in: ctx)
        case .text:     drawText(ann)
        case .highlight: drawHighlight(ann, in: ctx)
        case .mosaic:   drawEffect(ann, in: ctx)
        case .blur:     drawEffect(ann, in: ctx)
        }
    }

    private func drawRect(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineJoin(.miter)
        if ann.hasDropShadow {
            ctx.setShadow(offset: CGSize(width: 2, height: -2), blur: 4,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        ctx.stroke(ann.rect)
    }

    private func drawEllipse(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.strokeEllipse(in: ann.rect)
    }

    private func drawArrow(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        let start = ann.startPoint, end = ann.endPoint
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(ann.lineWidth * 4, 12)
        let headAngle = CGFloat.pi / 6
        let tip1 = CGPoint(x: end.x - headLength * cos(angle - headAngle),
                           y: end.y - headLength * sin(angle - headAngle))
        let tip2 = CGPoint(x: end.x - headLength * cos(angle + headAngle),
                           y: end.y - headLength * sin(angle + headAngle))
        ctx.setFillColor(ann.color.cgColor)
        ctx.move(to: end)
        ctx.addLine(to: tip1)
        ctx.addLine(to: tip2)
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawText(_ ann: Annotation) {
        guard !ann.text.isEmpty else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: ann.fontSize, weight: .semibold),
            .foregroundColor: ann.color,
            .backgroundColor: NSColor.white.withAlphaComponent(0.75),
            .shadow: shadow,
        ]
        NSAttributedString(string: ann.text, attributes: attrs).draw(at: ann.startPoint)
    }

    private func drawHighlight(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setFillColor(ann.color.withAlphaComponent(0.35).cgColor)
        ctx.fill(ann.rect)
    }

    private func drawEffect(_ ann: Annotation, in ctx: CGContext) {
        let r = ann.rect
        guard r.width > 1, r.height > 1 else { return }

        // Use cached image if rect matches
        if let cached = ann.cachedEffectImage, let cachedRect = ann.cachedEffectRect,
           cachedRect == r {
            ctx.draw(cached, in: r)
            return
        }

        // Live render from baseCGImage crop
        guard let base = baseCGImage else { return }
        let scaleX = CGFloat(base.width) / bounds.width
        let scaleY = CGFloat(base.height) / bounds.height
        let cropRect = CGRect(x: r.minX * scaleX, y: r.minY * scaleY,
                              width: r.width * scaleX, height: r.height * scaleY)
        guard let crop = base.cropping(to: cropRect) else { return }

        let processed: CGImage?
        switch ann.kind {
        case .mosaic: processed = Pixelator.mosaic(image: crop, scale: 12)
        case .blur:   processed = Pixelator.blur(image: crop, radius: 10)
        default: return
        }
        guard let result = processed else { return }
        ctx.draw(result, in: r)
    }

    private func populateEffectCache(for ann: Annotation) {
        let r = ann.rect
        guard (ann.kind == .mosaic || ann.kind == .blur),
              r.width > 1, r.height > 1,
              let base = baseCGImage else { return }
        let scaleX = CGFloat(base.width) / bounds.width
        let scaleY = CGFloat(base.height) / bounds.height
        let cropRect = CGRect(x: r.minX * scaleX, y: r.minY * scaleY,
                              width: r.width * scaleX, height: r.height * scaleY)
        guard let crop = base.cropping(to: cropRect) else { return }
        let processed: CGImage?
        switch ann.kind {
        case .mosaic: processed = Pixelator.mosaic(image: crop, scale: 12)
        case .blur:   processed = Pixelator.blur(image: crop, radius: 10)
        default: return
        }
        ann.cachedEffectImage = processed
        ann.cachedEffectRect = r
    }

    // MARK: Selection chrome

    private func drawSelectionChrome(for ann: Annotation, context ctx: CGContext) {
        let selRect = ann.rect.insetBy(dx: -4, dy: -4)

        // Dashed outline
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.gray.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.stroke(selRect)
        ctx.restoreGState()

        // Corner handles (not for arrow or text)
        guard supportsResizeHandles(ann.kind) else { return }
        let corners = cornerPoints(of: selRect)
        for corner in corners {
            let handleRect = CGRect(x: corner.x - handleSize / 2,
                                    y: corner.y - handleSize / 2,
                                    width: handleSize, height: handleSize)
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(handleRect)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(handleRect)
            ctx.restoreGState()
        }
    }

    private func cornerPoints(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY), // TL (flipped coords: maxY is top visually)
            CGPoint(x: rect.maxX, y: rect.maxY), // TR
            CGPoint(x: rect.minX, y: rect.minY), // BL
            CGPoint(x: rect.maxX, y: rect.minY), // BR
        ]
    }

    private func supportsResizeHandles(_ kind: AnnotationTool) -> Bool {
        switch kind {
        case .rect, .ellipse, .highlight, .mosaic, .blur: return true
        default: return false
        }
    }

    // MARK: - Hit testing

    private func hitAnnotation(at point: CGPoint) -> Annotation? {
        // Return topmost (last in array)
        for ann in annotations.reversed() {
            if hitTest(point: point, annotation: ann) { return ann }
        }
        return nil
    }

    private func hitTest(point p: CGPoint, annotation ann: Annotation) -> Bool {
        switch ann.kind {
        case .select: return false
        case .rect, .ellipse, .highlight, .mosaic, .blur:
            return ann.rect.insetBy(dx: -annotationHitPadding, dy: -annotationHitPadding).contains(p)
        case .arrow:
            return pointToSegmentDistance(p, from: ann.startPoint, to: ann.endPoint)
                   < max(6, ann.lineWidth + 3)
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: ann.fontSize, weight: .semibold)
            ]
            let size = (ann.text as NSString).size(withAttributes: attrs)
            let textRect = CGRect(origin: ann.startPoint, size: size)
            return textRect.insetBy(dx: -annotationHitPadding, dy: -annotationHitPadding).contains(p)
        }
    }

    private func pointToSegmentDistance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    /// Returns the opposite corner for resizing, or nil if p is not over a handle.
    private func hitResizeHandle(at p: CGPoint, for ann: Annotation) -> CGPoint? {
        guard supportsResizeHandles(ann.kind) else { return nil }
        let selRect = ann.rect.insetBy(dx: -4, dy: -4)
        let corners = cornerPoints(of: selRect)
        // opposite index: 0↔3 (TL↔BR), 1↔2 (TR↔BL)
        let opposites = [3, 2, 1, 0]
        for (i, corner) in corners.enumerated() {
            if hypot(p.x - corner.x, p.y - corner.y) <= handleRadius {
                return corners[opposites[i]]
            }
        }
        return nil
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)

        switch selectedTool {
        case .select:
            handleSelectMouseDown(at: p)

        case .text:
            spawnInlineTextField(at: p)

        default:
            // Drawing tool
            pushUndoSnapshot()
            let ann = Annotation(kind: selectedTool,
                                 startPoint: p,
                                 endPoint: p,
                                 color: currentColor,
                                 lineWidth: currentLineWidth,
                                 fontSize: currentFontSize,
                                 hasDropShadow: currentDropShadow)
            currentAnnotation = ann
            canvasState = .drafting
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        switch canvasState {
        case .drafting:
            currentAnnotation?.endPoint = p
            needsDisplay = true

        case .moving(let id, let dragOrigin, let origStart, let origEnd):
            if !didPushUndoForSelectionInteraction {
                pushUndoSnapshot()
                didPushUndoForSelectionInteraction = true
            }
            let dx = p.x - dragOrigin.x
            let dy = p.y - dragOrigin.y
            if let ann = annotations.first(where: { $0.id == id }) {
                ann.startPoint = CGPoint(x: origStart.x + dx, y: origStart.y + dy)
                ann.endPoint   = CGPoint(x: origEnd.x   + dx, y: origEnd.y   + dy)
                ann.invalidateEffectCache()
            }
            needsDisplay = true

        case .resizing(let id, let oppositeCorner):
            if !didPushUndoForSelectionInteraction {
                pushUndoSnapshot()
                didPushUndoForSelectionInteraction = true
            }
            if let ann = annotations.first(where: { $0.id == id }) {
                ann.startPoint = oppositeCorner
                ann.endPoint = p
                ann.invalidateEffectCache()
            }
            needsDisplay = true

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            didPushUndoForSelectionInteraction = false
        }

        switch canvasState {
        case .drafting:
            if let draft = currentAnnotation {
                let keep = draft.kind == .arrow || draft.hasMinimumSize
                if keep {
                    annotations.append(draft)
                    selectedAnnotationID = draft.id
                    if draft.kind == .mosaic || draft.kind == .blur {
                        draft.invalidateEffectCache()
                        populateEffectCache(for: draft)
                    }
                    delegate?.canvasDidMutate(self)
                    delegate?.canvasDidChangeSelection(self)
                } else {
                    // Discard: undo the snapshot we pushed
                    canvasUndoManager.undo()
                }
                currentAnnotation = nil
            }
            canvasState = .idle
            needsDisplay = true

        case .moving(let id, _, _, _):
            if let ann = annotations.first(where: { $0.id == id }) {
                if ann.kind == .mosaic || ann.kind == .blur {
                    ann.invalidateEffectCache()
                    populateEffectCache(for: ann)
                }
                delegate?.canvasDidMutate(self)
            }
            canvasState = .idle
            needsDisplay = true

        case .resizing(let id, _):
            if let ann = annotations.first(where: { $0.id == id }) {
                if ann.kind == .mosaic || ann.kind == .blur {
                    ann.invalidateEffectCache()
                    populateEffectCache(for: ann)
                }
                delegate?.canvasDidMutate(self)
            }
            canvasState = .idle
            needsDisplay = true

        default:
            break
        }
    }

    private func handleSelectMouseDown(at p: CGPoint) {
        // Check resize handle of current selection first
        if let selID = selectedAnnotationID,
           let selAnn = annotations.first(where: { $0.id == selID }),
           let opposite = hitResizeHandle(at: p, for: selAnn) {
            didPushUndoForSelectionInteraction = false
            canvasState = .resizing(id: selID, oppositeCorner: opposite)
            return
        }

        // Hit test annotation
        if let ann = hitAnnotation(at: p) {
            selectedAnnotationID = ann.id
            didPushUndoForSelectionInteraction = false
            canvasState = .moving(id: ann.id, dragOrigin: p,
                                  originalStart: ann.startPoint, originalEnd: ann.endPoint)
            delegate?.canvasDidChangeSelection(self)
            needsDisplay = true
            return
        }

        // Deselect
        selectedAnnotationID = nil
        canvasState = .idle
        delegate?.canvasDidChangeSelection(self)
        needsDisplay = true
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        guard selectedTool == .select else { super.keyDown(with: event); return }
        let del = event.keyCode == 51 || event.keyCode == 117 // Backspace or Delete
        if del, selectedAnnotationID != nil {
            deleteSelected()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Public actions

    func deleteSelected() {
        guard let selID = selectedAnnotationID else { return }
        pushUndoSnapshot()
        annotations.removeAll { $0.id == selID }
        selectedAnnotationID = nil
        delegate?.canvasDidMutate(self)
        delegate?.canvasDidChangeSelection(self)
        needsDisplay = true
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        pushUndoSnapshot()
        annotations.removeAll()
        selectedAnnotationID = nil
        currentAnnotation = nil
        delegate?.canvasDidMutate(self)
        delegate?.canvasDidChangeSelection(self)
        needsDisplay = true
    }

    // MARK: - Inline text field

    private func spawnInlineTextField(at point: CGPoint) {
        cancelTextEditingIfNeeded()
        inlineTextFieldOrigin = point

        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - currentFontSize,
                                              width: 200, height: currentFontSize + 8))
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.backgroundColor = .clear
        field.textColor = currentColor
        field.font = NSFont.systemFont(ofSize: currentFontSize, weight: .semibold)
        field.placeholderString = "Type here…"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        inlineTextField = field
        canvasState = .textEditing
    }

    private func cancelTextEditingIfNeeded() {
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        if case .textEditing = canvasState { canvasState = .idle }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitInlineText(cancel: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitInlineText(cancel: true)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineText(cancel: false)
            return true
        }
        return false
    }

    private func commitInlineText(cancel: Bool) {
        guard let field = inlineTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        inlineTextField = nil
        canvasState = .idle

        if !cancel && !text.isEmpty {
            pushUndoSnapshot()
            let ann = Annotation(kind: .text,
                                 startPoint: inlineTextFieldOrigin,
                                 endPoint: inlineTextFieldOrigin,
                                 color: currentColor,
                                 lineWidth: currentLineWidth,
                                 text: text,
                                 fontSize: currentFontSize,
                                 hasDropShadow: currentDropShadow)
            annotations.append(ann)
            selectedAnnotationID = ann.id
            delegate?.canvasDidMutate(self)
            delegate?.canvasDidChangeSelection(self)
            needsDisplay = true
        }

        window?.makeFirstResponder(self)
    }

    // MARK: - Undo / Redo

    private func pushUndoSnapshot() {
        let snapshot = annotations.map { $0.copy() as! Annotation }
        let selectedID = selectedAnnotationID
        canvasUndoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.restoreAnnotationsSnapshot(snapshot, selectedID: selectedID)
        }
        delegate?.canvasDidUpdateUndoState(self)
    }

    private func restoreAnnotationsSnapshot(_ snapshot: [Annotation], selectedID: UUID?) {
        pushUndoSnapshot() // register redo
        annotations = snapshot
        selectedAnnotationID = selectedID
        needsDisplay = true
        delegate?.canvasDidUpdateUndoState(self)
        delegate?.canvasDidChangeSelection(self)
        delegate?.canvasDidMutate(self)
    }

    // MARK: - Cursor

    func updateCursor() {
        switch selectedTool {
        case .select:
            NSCursor.arrow.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch selectedTool {
        case .select:
            if let selID = selectedAnnotationID,
               let selAnn = annotations.first(where: { $0.id == selID }),
               hitResizeHandle(at: p, for: selAnn) != nil {
                NSCursor.crosshair.set()
            } else if hitAnnotation(at: p) != nil {
                NSCursor.arrow.set()
            } else {
                NSCursor.arrow.set()
            }
        default:
            NSCursor.crosshair.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

import Cocoa

/// Pure-data state-machine driver for the in-place overlay editor.
///
/// Holds annotations (in selection-local coords) + selection rect + the active
/// interaction. NSView/NSWindow code calls into this; this code does not import AppKit-UI.
final class OverlayState {

    private(set) var selection: NSRect = .zero
    private(set) var annotations: [Annotation] = []
    private(set) var phase: Phase = .idle
    private(set) var selectedTool: AnnotationTool = .select
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 3
    var currentFontSize: CGFloat = 18
    var currentDropShadow: Bool = false
    private(set) var selectedAnnotationID: UUID?

    enum Phase: Equatable {
        case idle
        case drafting(start: NSPoint)
        case drafted
        case resizing(handle: ResizeHandle)
        case moving(originalSelectionOrigin: NSPoint, dragStart: NSPoint)
        case annotating(id: UUID)
    }

    enum SelectTarget {
        case handle(ResizeHandle)
        case selectionInterior
        case annotation(UUID)
        case nothing
    }

    // MARK: - Idle / drafting

    func beginDrafting(at point: NSPoint) {
        phase = .drafting(start: point)
        selection = NSRect(origin: point, size: .zero)
    }

    func updateDrafting(to point: NSPoint) {
        guard case .drafting(let start) = phase else { return }
        selection = NSRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
    }

    @discardableResult
    func finishDrafting() -> Bool {
        guard case .drafting = phase else { return false }
        if selection.width < 5 || selection.height < 5 {
            phase = .idle
            selection = .zero
            return false
        }
        phase = .drafted
        return true
    }

    // MARK: - Drafted-state hit testing

    func target(for point: NSPoint) -> SelectTarget {
        guard phase == .drafted || isResizingOrMoving else { return .nothing }
        if let h = ResizeHandle.handle(at: point, in: selection) {
            return .handle(h)
        }
        let local = NSPoint(x: point.x - selection.minX, y: point.y - selection.minY)
        for ann in annotations.reversed() {
            if hitTest(annotation: ann, point: local) {
                return .annotation(ann.id)
            }
        }
        if selection.contains(point) {
            return .selectionInterior
        }
        return .nothing
    }

    private var isResizingOrMoving: Bool {
        switch phase {
        case .resizing, .moving: return true
        default: return false
        }
    }

    private func hitTest(annotation a: Annotation, point: NSPoint) -> Bool {
        switch a.kind {
        case .rect, .ellipse, .highlight, .mosaic, .blur:
            return a.rect.insetBy(dx: -6, dy: -6).contains(point)
        case .arrow:
            return distance(point, segment: a.startPoint, to: a.endPoint) < max(6, a.lineWidth + 3)
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)]
            let size = (a.text as NSString).size(withAttributes: attrs)
            return NSRect(origin: a.startPoint, size: size).insetBy(dx: -6, dy: -6).contains(point)
        case .select:
            return false
        }
    }

    private func distance(_ p: NSPoint, segment a: NSPoint, to b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx*dx + dy*dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let proj = NSPoint(x: a.x + t*dx, y: a.y + t*dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    // MARK: - Resizing / moving

    func beginResizing(handle: ResizeHandle) {
        phase = .resizing(handle: handle)
    }

    func updateResizing(to point: NSPoint) {
        guard case .resizing(let h) = phase else { return }
        selection = h.resize(rect: selection, to: point)
    }

    func beginMoving(at point: NSPoint) {
        phase = .moving(originalSelectionOrigin: selection.origin, dragStart: point)
    }

    func updateMoving(to point: NSPoint) {
        guard case .moving(let originalOrigin, let dragStart) = phase else { return }
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        selection.origin = NSPoint(x: originalOrigin.x + dx, y: originalOrigin.y + dy)
    }

    func finishGesture() {
        phase = .drafted
    }

    // MARK: - Annotations

    func setSelectedTool(_ tool: AnnotationTool) {
        selectedTool = tool
        selectedAnnotationID = nil
    }

    func selectAnnotation(_ id: UUID?) {
        selectedAnnotationID = id
    }

    func addAnnotation(_ ann: Annotation) {
        annotations.append(ann)
    }

    func removeSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        selectedAnnotationID = nil
    }

    func clearAnnotations() {
        annotations.removeAll()
        selectedAnnotationID = nil
    }

    // MARK: - Cancel

    func cancel() {
        phase = .idle
        selection = .zero
        annotations.removeAll()
        selectedAnnotationID = nil
    }
}

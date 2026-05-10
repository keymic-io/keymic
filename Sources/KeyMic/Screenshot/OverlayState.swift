import Cocoa

/// Pure-data state-machine driver for the in-place overlay editor.
///
/// Holds annotations (in selection-local coords) + selection rect + the active
/// interaction. NSView/NSWindow code calls into this; this code does not import AppKit-UI.
final class ScreenshotOverlayState {

    private(set) var selection: NSRect = .zero
    private(set) var annotations: [Annotation] = []
    private(set) var phase: Phase = .idle
    private(set) var selectedTool: AnnotationTool = .select
    /// View-local bounds used to clamp the selection rect. `.zero` disables clamping.
    var screenBounds: NSRect = .zero
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

    /// Directly sets the selection to a known rect (e.g. a detected window) and enters drafted state.
    func commitWindowSelection(_ rect: NSRect) {
        selection = clampToScreen(rect)
        phase = .drafted
    }

    private func clampToScreen(_ rect: NSRect) -> NSRect {
        guard screenBounds != .zero else { return rect }
        return rect.intersection(screenBounds)
    }

    private func clampOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        guard screenBounds != .zero else { return origin }
        let maxX = max(screenBounds.minX, screenBounds.maxX - size.width)
        let maxY = max(screenBounds.minY, screenBounds.maxY - size.height)
        return NSPoint(
            x: min(maxX, max(screenBounds.minX, origin.x)),
            y: min(maxY, max(screenBounds.minY, origin.y))
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
        case .pen:
            let threshold = max(8, a.lineWidth + 4)
            for i in 1..<a.points.count {
                if distance(point, segment: a.points[i-1], to: a.points[i]) < threshold { return true }
            }
            return false
        case .select, .ocr:
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
        selection = clampToScreen(h.resize(rect: selection, to: point))
    }

    func beginMoving(at point: NSPoint) {
        phase = .moving(originalSelectionOrigin: selection.origin, dragStart: point)
    }

    func updateMoving(to point: NSPoint) {
        guard case .moving(let originalOrigin, let dragStart) = phase else { return }
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        let candidate = NSPoint(x: originalOrigin.x + dx, y: originalOrigin.y + dy)
        selection.origin = clampOrigin(candidate, size: selection.size)
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

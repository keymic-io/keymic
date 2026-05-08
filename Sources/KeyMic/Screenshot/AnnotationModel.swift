import Cocoa

enum AnnotationTool: String, CaseIterable {
    case select = "Select"
    case rect = "Rectangle"
    case ellipse = "Ellipse"
    case arrow = "Arrow"
    case text = "Text"
    case highlight = "Highlight"
    case mosaic = "Mosaic"
    case blur = "Blur"
    case ocr = "OCR"

    var isDrawingTool: Bool {
        switch self {
        case .select, .ocr: return false
        default: return true
        }
    }

    var iconName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .mosaic: return "mosaic"
        case .blur: return "circle.dashed"
        case .ocr: return "text.viewfinder"
        }
    }

    var displayName: String { rawValue }
}

class Annotation: NSCopying {
    let id: UUID
    let kind: AnnotationTool
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var text: String
    var fontSize: CGFloat
    var hasDropShadow: Bool

    var cachedEffectImage: CGImage?
    var cachedEffectRect: CGRect?

    var rect: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    var hasMinimumSize: Bool { rect.width > 3 || rect.height > 3 }

    init(
        kind: AnnotationTool,
        startPoint: CGPoint,
        endPoint: CGPoint = .zero,
        color: NSColor = .systemRed,
        lineWidth: CGFloat = 3,
        text: String = "",
        fontSize: CGFloat = 18,
        hasDropShadow: Bool = false
    ) {
        self.id = UUID()
        self.kind = kind
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
        self.hasDropShadow = hasDropShadow
    }

    func copy(with zone: NSZone? = nil) -> Any {
        let copy = Annotation(
            kind: kind,
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            text: text,
            fontSize: fontSize,
            hasDropShadow: hasDropShadow
        )
        return copy
    }

    func invalidateEffectCache() {
        cachedEffectImage = nil
        cachedEffectRect = nil
    }
}

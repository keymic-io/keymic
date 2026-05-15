import Cocoa

enum AnnotationTool: String, CaseIterable {
    case select = "Select"
    case pen = "Pen"
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
        case .pen: return "scribble"
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

    var displayName: String {
        switch self {
        case .select: return String(localized: "Select")
        case .pen: return String(localized: "Pen")
        case .rect: return String(localized: "Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .arrow: return String(localized: "Arrow")
        case .text: return String(localized: "Text")
        case .highlight: return String(localized: "Highlight")
        case .mosaic: return String(localized: "Mosaic")
        case .blur: return String(localized: "Blur")
        case .ocr: return "OCR"
        }
    }
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
    var points: [CGPoint] = []  // freehand pen path points (selection-local coords)

    var cachedEffectImage: CGImage?
    var cachedEffectRect: CGRect?

    var rect: CGRect {
        if kind == .pen, !points.isEmpty {
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!
            let minY = ys.min()!, maxY = ys.max()!
            return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }
        return CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    var hasMinimumSize: Bool {
        if kind == .pen { return points.count >= 2 }
        return rect.width > 3 || rect.height > 3
    }

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
        copy.points = points
        return copy
    }

    func invalidateEffectCache() {
        cachedEffectImage = nil
        cachedEffectRect = nil
    }
}

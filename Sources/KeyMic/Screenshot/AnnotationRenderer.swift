import Cocoa

enum AnnotationRenderer {
    static func render(base: CGImage, annotations: [Annotation]) -> NSImage {
        let effectRegions = annotations.compactMap { ann -> (CGRect, AnnotationTool)? in
            switch ann.kind {
            case .mosaic, .blur: return (ann.rect, ann.kind)
            default: return nil
            }
        }

        let baseImage: CGImage
        if effectRegions.isEmpty {
            baseImage = base
        } else if let composited = Pixelator.compositeMaskedRegions(base: base, regions: effectRegions) {
            baseImage = composited
        } else {
            baseImage = base
        }

        let size = NSSize(width: baseImage.width, height: baseImage.height)
        let rendered = NSImage(size: size, flipped: false) { drawRect in
            NSImage(cgImage: baseImage, size: size).draw(in: drawRect)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            for ann in annotations {
                switch ann.kind {
                case .mosaic, .blur, .select: continue
                case .rect: drawRectAnnotation(ann, in: ctx)
                case .ellipse: drawEllipseAnnotation(ann, in: ctx)
                case .arrow: drawArrowAnnotation(ann, in: ctx)
                case .text: drawTextAnnotation(ann)
                case .highlight: drawHighlightAnnotation(ann, in: ctx)
                }
            }
            return true
        }
        return rendered
    }

    private static func drawRectAnnotation(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineJoin(.miter)
        if ann.hasDropShadow {
            ctx.setShadow(offset: CGSize(width: 2, height: -2), blur: 4,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        ctx.stroke(ann.rect)
    }

    private static func drawEllipseAnnotation(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.strokeEllipse(in: ann.rect)
    }

    private static func drawArrowAnnotation(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
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

    private static func drawTextAnnotation(_ ann: Annotation) {
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

    private static func drawHighlightAnnotation(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(ann.color.withAlphaComponent(0.35).cgColor)
        ctx.fill(ann.rect)
    }
}

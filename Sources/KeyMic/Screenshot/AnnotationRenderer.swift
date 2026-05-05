import Cocoa

enum AnnotationRenderer {
    /// Renders annotations onto the base image at the base image's native pixel resolution.
    ///
    /// `pointSize` is the size of the canvas in points — annotations are stored in this
    /// coordinate space. The renderer scales to map point coords into the pixel-resolution
    /// output. If `pointSize == .zero`, falls back to treating the base image dimensions
    /// as the point space (1x).
    static func render(base: CGImage, annotations: [Annotation], pointSize: NSSize = .zero) -> NSImage {
        let effectRegions = annotations.compactMap { ann -> (CGRect, AnnotationTool)? in
            switch ann.kind {
            case .mosaic, .blur:
                let scale = effectiveScale(base: base, pointSize: pointSize)
                let pxRect = CGRect(
                    x: ann.rect.origin.x * scale,
                    y: ann.rect.origin.y * scale,
                    width: ann.rect.width * scale,
                    height: ann.rect.height * scale
                )
                return (pxRect, ann.kind)
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

        let pixelSize = NSSize(width: baseImage.width, height: baseImage.height)
        let renderPointSize: NSSize = (pointSize == .zero) ? pixelSize : pointSize
        let scale = effectiveScale(base: base, pointSize: pointSize)

        // Render at native pixel resolution but draw annotations in point space via CTM scale.
        let rendered = NSImage(size: pixelSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // Draw base at pixel size (fills entire image).
            ctx.draw(baseImage, in: CGRect(origin: .zero, size: pixelSize))
            // Scale CTM so annotation point coords map to pixel positions.
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            for ann in annotations {
                switch ann.kind {
                case .mosaic, .blur, .select: continue
                case .rect: drawRectAnnotation(ann, in: ctx)
                case .ellipse: drawEllipseAnnotation(ann, in: ctx)
                case .arrow: drawArrowAnnotation(ann, in: ctx)
                case .text: drawTextAnnotation(ann, scale: scale)
                case .highlight: drawHighlightAnnotation(ann, in: ctx)
                }
            }
            ctx.restoreGState()
            _ = renderPointSize  // keep capture for clarity
            return true
        }
        return rendered
    }

    private static func effectiveScale(base: CGImage, pointSize: NSSize) -> CGFloat {
        guard pointSize.width > 0 else { return 1 }
        return CGFloat(base.width) / pointSize.width
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

    private static func drawTextAnnotation(_ ann: Annotation, scale: CGFloat) {
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
        _ = scale  // CTM scale applied by caller; text draws in point space
        NSAttributedString(string: ann.text, attributes: attrs).draw(at: ann.startPoint)
    }

    private static func drawHighlightAnnotation(_ ann: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(ann.color.withAlphaComponent(0.35).cgColor)
        ctx.fill(ann.rect)
    }
}

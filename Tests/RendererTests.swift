import Cocoa

@main
struct RendererTests {
    static func main() {
        testRenderWithNoAnnotations()
        testRenderWithRectAnnotation()
        testRenderWithHighlightAnnotation()
        testOutputDimensions()
        print("✅ Renderer tests passed")
    }

    static func createFixtureImage() -> CGImage {
        let w = 200, h = 200
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func testRenderWithNoAnnotations() {
        let img = createFixtureImage()
        let result = AnnotationRenderer.render(base: img, annotations: [])
        assert(result.size.width > 0)
        assert(result.size.height > 0)
    }

    static func testRenderWithRectAnnotation() {
        let img = createFixtureImage()
        let ann = Annotation(kind: .rect, startPoint: CGPoint(x: 10, y: 10),
                             endPoint: CGPoint(x: 100, y: 100), color: .systemRed, lineWidth: 3)
        let result = AnnotationRenderer.render(base: img, annotations: [ann])
        assert(result.size.width > 0)
    }

    static func testRenderWithHighlightAnnotation() {
        let img = createFixtureImage()
        let ann = Annotation(kind: .highlight, startPoint: CGPoint(x: 20, y: 20),
                             endPoint: CGPoint(x: 80, y: 80), color: .systemYellow)
        let result = AnnotationRenderer.render(base: img, annotations: [ann])
        assert(result.size.width > 0)
    }

    static func testOutputDimensions() {
        let img = createFixtureImage()
        let result = AnnotationRenderer.render(base: img, annotations: [])
        assert(Int(result.size.width) == img.width)
        assert(Int(result.size.height) == img.height)
    }
}

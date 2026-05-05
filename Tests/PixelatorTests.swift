import Cocoa
import CoreImage

@main
struct PixelatorTests {
    static func main() {
        testMosaic()
        testBlur()
        testCompositeMaskedRegions()
        print("✅ Pixelator tests passed")
    }

    static func createFixtureImage() -> CGImage {
        let w = 100, h = 100
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for x in 0..<w {
            for y in 0..<h {
                ctx.setFillColor(CGColor(red: Double(x)/100, green: Double(y)/100, blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    static func testMosaic() {
        let img = createFixtureImage()
        guard let result = Pixelator.mosaic(image: img, scale: 12) else {
            fatalError("mosaic returned nil")
        }
        assert(result.width == img.width)
        assert(result.height == img.height)
    }

    static func testBlur() {
        let img = createFixtureImage()
        guard let result = Pixelator.blur(image: img, radius: 10) else {
            fatalError("blur returned nil")
        }
        assert(result.width == img.width)
        assert(result.height == img.height)
    }

    static func testCompositeMaskedRegions() {
        let img = createFixtureImage()
        let regions: [(rect: CGRect, kind: AnnotationTool)] = [
            (rect: CGRect(x: 10, y: 10, width: 30, height: 30), kind: .mosaic),
            (rect: CGRect(x: 50, y: 50, width: 30, height: 30), kind: .blur),
        ]
        guard let result = Pixelator.compositeMaskedRegions(base: img, regions: regions) else {
            fatalError("compositeMaskedRegions returned nil")
        }
        assert(result.width == img.width)
        assert(result.height == img.height)
    }
}

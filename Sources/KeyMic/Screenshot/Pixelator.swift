import CoreImage
import Cocoa

struct Pixelator {
    private static let ciContext = CIContext()

    static func mosaic(image: CGImage, scale: CGFloat = 12) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: ciImage.extent)
    }

    static func blur(image: CGImage, radius: CGFloat = 10) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: ciImage.extent)
    }

    static func compositeMaskedRegions(
        base: CGImage,
        regions: [(rect: CGRect, kind: AnnotationTool)]
    ) -> CGImage? {
        let ciBase = CIImage(cgImage: base)
        let extent = ciBase.extent

        let mosaicFull = mosaic(image: base, scale: 12).map { CIImage(cgImage: $0) }
        let blurFull = blur(image: base, radius: 10).map { CIImage(cgImage: $0) }

        var current = ciBase

        for region in regions {
            let effectImage: CIImage?
            switch region.kind {
            case .mosaic: effectImage = mosaicFull
            case .blur: effectImage = blurFull
            default: continue
            }
            guard let effect = effectImage else { continue }

            guard let maskFilter = CIFilter(name: "CIConstantColorGenerator") else { continue }
            maskFilter.setValue(CIColor.white, forKey: kCIInputColorKey)
            guard let maskColor = maskFilter.outputImage?.cropped(to: region.rect) else { continue }

            guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { continue }
            blendFilter.setValue(effect, forKey: kCIInputImageKey)
            blendFilter.setValue(current, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskColor, forKey: kCIInputMaskImageKey)
            guard let blended = blendFilter.outputImage else { continue }

            current = blended
        }

        return ciContext.createCGImage(current, from: extent)
    }
}

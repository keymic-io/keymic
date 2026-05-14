import AppKit
import CoreGraphics
import Foundation
import ImageIO

@main
struct ThumbnailCacheTestRunner {
    static func main() throws {
        let tmp = URL(
            fileURLWithPath: "/tmp/keymic-thumb-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pngURL = tmp.appendingPathComponent("img.png")
        try writeSolidPNG(at: pngURL, width: 400, height: 300)

        let loader = ThumbnailLoader(maxPixels: 200)

        // Synchronously load using the loader's testing hook.
        let image = try loader.loadForTesting(fileURL: pngURL)
        expect(image.size.width <= 200 && image.size.height <= 200, "downsampled to <=200px max")

        // Second load hits the cache (same NSImage instance returned).
        let again = try loader.loadForTesting(fileURL: pngURL)
        expect(again === image, "cache hit returns same NSImage instance")

        print("ThumbnailCacheTests passed")
    }

    private static func writeSolidPNG(at url: URL, width: Int, height: Int) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0x80, count: bytesPerRow * height)
        guard
            let ctx = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let cg = ctx.makeImage(),
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else {
            throw NSError(domain: "ThumbnailCacheTests", code: 1)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "ThumbnailCacheTests", code: 2)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

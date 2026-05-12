import AppKit
import ImageIO

final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let maxPixels: Int
    private let workQueue = DispatchQueue(
        label: "io.keymic.app.thumbnails",
        qos: .userInitiated, attributes: .concurrent)

    init(maxPixels: Int = 200) {
        self.maxPixels = maxPixels
        cache.countLimit = 200
    }

    /// Returns an in-memory thumbnail if cached, or nil. Schedules a background
    /// load + `completion(image)` on the main queue otherwise.
    func thumbnail(fileURL: URL, completion: @escaping (NSImage?) -> Void) -> NSImage? {
        if let cached = cache.object(forKey: fileURL as NSURL) {
            return cached
        }
        workQueue.async { [weak self] in
            let image = try? self?.loadDownsampled(fileURL: fileURL)
            DispatchQueue.main.async {
                if let image, let self {
                    self.cache.setObject(image, forKey: fileURL as NSURL)
                }
                completion(image)
            }
        }
        return nil
    }

    /// Synchronous version used by tests. Throws on decode failure.
    func loadForTesting(fileURL: URL) throws -> NSImage {
        if let cached = cache.object(forKey: fileURL as NSURL) { return cached }
        let image = try loadDownsampled(fileURL: fileURL)
        cache.setObject(image, forKey: fileURL as NSURL)
        return image
    }

    private func loadDownsampled(fileURL: URL) throws -> NSImage {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else {
            throw NSError(domain: "ThumbnailLoader", code: 1)
        }
        let pixelSize = NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: pixelSize)
    }
}

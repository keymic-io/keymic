import AppKit

final class ApplicationImageCache {
    static let shared = ApplicationImageCache()

    private let cache = IconCache(capacity: 256)
    private let iconSize = NSSize(width: 16, height: 16)

    private init() {}

    func image(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return cache.image(forKey: bundleID) {
            let workspace = NSWorkspace.shared
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let raw = workspace.icon(forFile: url.path)
            return NSImage(size: iconSize, flipped: false) { rect in
                raw.draw(in: rect)
                return true
            }
        }
    }
}

final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = IconCache(capacity: 512)

    private init() {}

    func image(forPath path: String) -> NSImage {
        cache.image(forKey: path) {
            NSWorkspace.shared.icon(forFile: path)
        } ?? NSWorkspace.shared.icon(forFile: path)
    }
}

private final class IconCache {
    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var insertionOrder: [String] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func image(forKey key: String, load: () -> NSImage?) -> NSImage? {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let image = load() else { return nil }

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        cache[key] = image
        insertionOrder.append(key)
        if insertionOrder.count > capacity {
            let evict = insertionOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return image
    }
}

import AppKit

final class ApplicationImageCache {
    static let shared = ApplicationImageCache()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var insertionOrder: [String] = []
    private let capacity = 256
    private let iconSize = NSSize(width: 16, height: 16)

    private init() {}

    func image(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }

        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let raw = workspace.icon(forFile: url.path)
        let resized = NSImage(size: iconSize, flipped: false) { rect in
            raw.draw(in: rect)
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        // Recheck — another thread may have populated the entry while we were decoding.
        if let cached = cache[bundleID] { return cached }
        cache[bundleID] = resized
        insertionOrder.append(bundleID)
        if insertionOrder.count > capacity {
            let evict = insertionOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return resized
    }
}

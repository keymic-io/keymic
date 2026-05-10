import Cocoa

enum WindowFinder {
    /// Returns the AppKit-coordinate rect (bottom-left origin) of the topmost normal window at
    /// the given screen point. Returns nil if no suitable window is found.
    static func windowRect(atScreenPoint point: NSPoint) -> NSRect? {
        guard let mainH = NSScreen.screens.first?.frame.height else { return nil }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha > 0.1,
                let owner = info[kCGWindowOwnerName as String] as? String,
                owner != "KeyMic", owner != "Window Server",
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                cgRect.width > 50, cgRect.height > 50
            else { continue }

            // CGWindowListCopyWindowInfo bounds use top-left origin with Y increasing downward.
            // AppKit uses bottom-left origin with Y increasing upward.
            let appKitRect = NSRect(
                x: cgRect.minX,
                y: mainH - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )
            if appKitRect.contains(point) {
                return appKitRect
            }
        }
        return nil
    }
}

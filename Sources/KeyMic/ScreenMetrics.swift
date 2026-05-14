import AppKit

struct ScreenMetrics {
    let frame: NSRect
    let visibleFrame: NSRect

    var width: CGFloat { frame.width }
    var height: CGFloat { frame.height }
    var visibleWidth: CGFloat { visibleFrame.width }
    var visibleHeight: CGFloat { visibleFrame.height }
}

/// Global screen metrics captured at app launch. Refresh via `AppScreen.refresh()`
/// when the active display changes if needed.
enum AppScreen {
    static private(set) var main: ScreenMetrics = capture()

    static func refresh() {
        main = capture()
    }

    private static func capture() -> ScreenMetrics {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? frame
        return ScreenMetrics(frame: frame, visibleFrame: visible)
    }
}

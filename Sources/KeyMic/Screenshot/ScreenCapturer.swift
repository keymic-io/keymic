import Cocoa
import ScreenCaptureKit
import os.log

enum ScreenshotError: Error {
    case permissionDenied
    case displayMismatch
    case unknown(Error)
}

actor ScreenCapturer {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "ScreenCapturer")
    func captureAllScreens() async throws -> [NSScreen: CGImage] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // No reliable typed predicate — TCC denial surfaces as a generic error here.
            throw ScreenshotError.permissionDenied
        }

        var result: [NSScreen: CGImage] = [:]
        for display in content.displays {
            // Match SCDisplay → NSScreen first, so we can use its backingScaleFactor.
            let matchedScreen = NSScreen.screens.first { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return id == display.displayID
            }
            // SCDisplay.width/height are logical (point) dimensions. SCStreamConfiguration
            // expects pixel dimensions — multiply by backingScaleFactor for Retina.
            let scale = matchedScreen?.backingScaleFactor ?? 2.0
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.scalesToFit = false
            config.captureResolution = .best
            do {
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                if let screen = matchedScreen {
                    result[screen] = cgImage
                }
            } catch {
                Self.logger.warning("display \(display.displayID) capture failed: \(error)")
                continue
            }
        }
        guard !result.isEmpty else { throw ScreenshotError.displayMismatch }
        return result
    }
}

import Cocoa
import ScreenCaptureKit

enum ScreenshotError: Error {
    case permissionDenied
    case displayMismatch
    case unknown(Error)
}

actor ScreenCapturer {
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
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.scalesToFit = false
            do {
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                if let screen = NSScreen.screens.first(where: { screen in
                    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                    return id == display.displayID
                }) {
                    result[screen] = cgImage
                }
            } catch {
                throw ScreenshotError.unknown(error)
            }
        }
        guard !result.isEmpty else { throw ScreenshotError.displayMismatch }
        return result
    }
}

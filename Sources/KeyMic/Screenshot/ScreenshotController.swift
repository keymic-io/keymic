import Cocoa

@MainActor
final class ScreenshotController {
    private let capturer = ScreenCapturer()
    private var frozenFrames: [NSScreen: CGImage] = [:]
    private var overlayPanels: [SelectionOverlayPanel] = []
    private var editorController: EditorWindowController?
    private var isCapturing = false

    // Drag state
    private var dragOwningScreen: NSScreen? = nil
    private var dragStartPoint: NSPoint? = nil
    private var dragCurrentPoint: NSPoint? = nil

    // Permission polling state
    private var permissionPollTimer: Timer?
    private var lastPermissionAlertAt: CFTimeInterval = 0
    private var permissionPollStartedAt: CFTimeInterval = 0
    private let permissionPollTimeout: CFTimeInterval = 120
    private let permissionAlertCooldown: CFTimeInterval = 10

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        Task { @MainActor in
            do {
                let frames = try await self.capturer.captureAllScreens()
                self.frozenFrames = frames
                self.showOverlays()
            } catch ScreenshotError.permissionDenied {
                self.isCapturing = false
                self.handlePermissionDenied()
            } catch {
                self.isCapturing = false
                NSLog("[Screenshot] capture failed: \(error)")
            }
        }
    }

    private func showOverlays() {
        overlayPanels = NSScreen.screens.map { screen in
            let panel = SelectionOverlayPanel(screen: screen)
            panel.onMouseDown = { [weak self] event, screen in self?.handleMouseDown(event: event, screen: screen) }
            panel.onMouseDragged = { [weak self] event, screen in self?.handleMouseDragged(event: event, screen: screen) }
            panel.onMouseUp = { [weak self] event, screen in self?.handleMouseUp(event: event, screen: screen) }
            panel.onMouseMoved = { [weak self] event, screen in self?.handleMouseMoved(event: event, screen: screen) }
            panel.onCancel = { [weak self] in self?.cancel() }
            return panel
        }
        for panel in overlayPanels {
            panel.makeKeyAndOrderFront(nil)
        }
        // Make the panel under the mouse key
        let mouseLoc = NSEvent.mouseLocation
        if let active = overlayPanels.first(where: { $0.owningScreen.frame.contains(mouseLoc) }) {
            active.makeKey()
        }
    }

    private func handleMouseDown(event: NSEvent, screen: NSScreen) {
        if dragOwningScreen != nil { return }  // already dragging
        dragOwningScreen = screen
        let p = event.locationInWindow  // in panel coords (panel == screen frame)
        dragStartPoint = p
        dragCurrentPoint = p
        // Freeze other panels' crosshair
        for panel in overlayPanels where panel.owningScreen !== screen {
            panel.setCursorPosition(nil, frozen: true)
        }
    }

    private func handleMouseDragged(event: NSEvent, screen: NSScreen) {
        guard dragOwningScreen === screen,
              let start = dragStartPoint else { return }
        let p = event.locationInWindow
        dragCurrentPoint = p
        let rect = NSRect(
            x: min(start.x, p.x), y: min(start.y, p.y),
            width: abs(p.x - start.x), height: abs(p.y - start.y)
        )
        if let panel = overlayPanels.first(where: { $0.owningScreen === screen }) {
            panel.setSelectionRect(rect)
            panel.setCursorPosition(p, frozen: false)
        }
    }

    private func handleMouseUp(event: NSEvent, screen: NSScreen) {
        guard dragOwningScreen === screen,
              let start = dragStartPoint else {
            cancel(); return
        }
        let p = event.locationInWindow
        let rect = NSRect(
            x: min(start.x, p.x), y: min(start.y, p.y),
            width: abs(p.x - start.x), height: abs(p.y - start.y)
        )
        // Reset state
        dragOwningScreen = nil
        dragStartPoint = nil
        dragCurrentPoint = nil
        if rect.width < 5 || rect.height < 5 {
            cancel()
            return
        }
        handleSelection(screen: screen, rectInPanelCoords: rect)
    }

    private func handleMouseMoved(event: NSEvent, screen: NSScreen) {
        if dragOwningScreen != nil { return }
        if let panel = overlayPanels.first(where: { $0.owningScreen === screen }) {
            panel.setCursorPosition(event.locationInWindow, frozen: false)
        }
    }

    private func handleSelection(screen: NSScreen, rectInPanelCoords rect: NSRect) {
        guard let frame = frozenFrames[screen] else { cancel(); return }
        // Panel coords = screen coords with bottom-left origin. CGImage is top-left.
        // Panel size matches screen frame in points; CGImage may be in pixels (Retina).
        let scaleX = CGFloat(frame.width) / screen.frame.width
        let scaleY = CGFloat(frame.height) / screen.frame.height
        let pxRect = CGRect(
            x: rect.origin.x * scaleX,
            y: (screen.frame.height - rect.origin.y - rect.height) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        guard let cropped = frame.cropping(to: pxRect) else { cancel(); return }

        dismissOverlays()
        let nsImage = NSImage(cgImage: cropped, size: rect.size)
        openEditor(with: nsImage)
        isCapturing = false
    }

    private func openEditor(with image: NSImage) {
        let controller = EditorWindowController(image: image)
        editorController = controller
        controller.showWindow()
    }

    private func dismissOverlays() {
        for panel in overlayPanels { panel.dismiss() }
        overlayPanels.removeAll()
    }

    func cancel() {
        dismissOverlays()
        frozenFrames.removeAll()
        dragOwningScreen = nil
        dragStartPoint = nil
        dragCurrentPoint = nil
        isCapturing = false
    }

    // MARK: Permission handling

    private func handlePermissionDenied() {
        let now = CACurrentMediaTime()
        if now - lastPermissionAlertAt < permissionAlertCooldown { return }
        lastPermissionAlertAt = now

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "KeyMic needs Screen Recording permission to take screenshots. Open System Settings → Privacy & Security → Screen Recording."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            startPermissionPoll()
        }
    }

    private func startPermissionPoll() {
        permissionPollTimer?.invalidate()
        permissionPollStartedAt = CACurrentMediaTime()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.permissionPollStartedAt
            if elapsed > self.permissionPollTimeout {
                timer.invalidate()
                self.permissionPollTimer = nil
                return
            }
            Task { @MainActor in
                do {
                    _ = try await self.capturer.captureAllScreens()
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    self.start()
                } catch {
                    // still no permission, keep polling
                }
            }
        }
    }
}

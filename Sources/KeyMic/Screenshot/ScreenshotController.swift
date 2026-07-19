import Cocoa
import Combine
import os.log

@MainActor
final class ScreenshotController: SelectionOverlayViewDelegate {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "Screenshot")
    private let capturer = ScreenCapturer()
    private let exporter = ScreenshotExporter()
    private var frozenFrames: [NSScreen: CGImage] = [:]
    private var overlayPanels: [SelectionOverlayPanel] = []
    private var ownerPanel: SelectionOverlayPanel?
    private var toolbarPanel: EditorToolbarPanel?
    private let state = EditorState()
    private var cancellables: Set<AnyCancellable> = []
    private var isCapturing = false

    private var permissionPollTimer: Timer?
    private var lastPermissionAlertAt: CFTimeInterval = 0
    private var permissionPollStartedAt: CFTimeInterval = 0
    private let permissionPollTimeout: CFTimeInterval = 120
    private let permissionAlertCooldown: CFTimeInterval = 10

    func start() {
        guard !isCapturing else { return }
        TelemetryService.shared.featureUsed("screenshot")
        isCapturing = true
        Task { @MainActor in
            do {
                let frames = try await capturer.captureAllScreens()
                self.frozenFrames = frames
                self.showOverlays()
            } catch ScreenshotError.permissionDenied {
                self.isCapturing = false
                self.handlePermissionDenied()
            } catch {
                self.isCapturing = false
                Self.logger.error("capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showOverlays() {
        overlayPanels = NSScreen.screens.map { screen in
            let panel = SelectionOverlayPanel(screen: screen)
            panel.overlayView.delegate = self
            panel.setFrozenFrame(frozenFrames[screen])
            panel.setOwner(true)
            return panel
        }
        for panel in overlayPanels {
            panel.makeKeyAndOrderFront(nil)
        }
        let mouseLoc = NSEvent.mouseLocation
        if let active = overlayPanels.first(where: { $0.owningScreen.frame.contains(mouseLoc) }) {
            active.makeKey()
        }
        bindStateActions()
    }

    private func bindStateActions() {
        state.selectedTool = .select
        state.selectedColor = .red
        state.lineWidth = 3
        state.fontSize = 18
        state.dropShadowEnabled = false
        state.isOCRAnalyzing = false

        cancellables.removeAll()
        state.$selectedTool.sink { [weak self] t in self?.ownerPanel?.overlayView.updateTool(t) }.store(in: &cancellables)
        state.$selectedColor.sink { [weak self] c in self?.ownerPanel?.overlayView.updateColor(NSColor(c)) }.store(in: &cancellables)
        state.$lineWidth.sink { [weak self] w in self?.ownerPanel?.overlayView.updateLineWidth(w) }.store(in: &cancellables)
        state.$fontSize.sink { [weak self] s in self?.ownerPanel?.overlayView.updateFontSize(s) }.store(in: &cancellables)
        state.$dropShadowEnabled.sink { [weak self] on in self?.ownerPanel?.overlayView.updateDropShadow(on) }.store(in: &cancellables)

        state.undoAction = { [weak self] in
            self?.ownerPanel?.overlayView.undoManager?.undo()
            self?.refreshUndoState()
        }
        state.redoAction = { [weak self] in
            self?.ownerPanel?.overlayView.undoManager?.redo()
            self?.refreshUndoState()
        }
        state.cancelAction = { [weak self] in self?.cancel() }
        state.confirmAction = { [weak self] in self?.confirmAndCopy() }
        state.saveAction = { [weak self] in self?.saveAndDismiss() }
    }

    // MARK: - SelectionOverlayViewDelegate

    func overlayDidEnterDrafted(_ view: SelectionOverlayView) {
        guard let panel = overlayPanels.first(where: { $0.contentView === view }) else { return }
        ownerPanel = panel
        for p in overlayPanels where p !== panel {
            p.setOwner(false)
        }
        showToolbar()
    }

    func overlayDidUpdateSelection(_ view: SelectionOverlayView) {
        repositionToolbar()
    }

    func overlayDidUpdateState(_ view: SelectionOverlayView) {
        refreshUndoState()
    }

    func overlayDidCancel(_ view: SelectionOverlayView) {
        cancel()
    }

    func overlayDidConfirm(_ view: SelectionOverlayView) {
        confirmAndCopy()
    }

    func overlayDidSave(_ view: SelectionOverlayView) {
        saveAndDismiss()
    }

    // MARK: - Toolbar

    private func showToolbar() {
        guard toolbarPanel == nil else { repositionToolbar(); return }
        let panel = EditorToolbarPanel(state: state)
        toolbarPanel = panel
        repositionToolbar()
        panel.orderFront(nil)
    }

    private func repositionToolbar() {
        guard let toolbar = toolbarPanel,
              let owner = ownerPanel else { return }
        toolbar.reposition(for: owner.overlayView.selection, on: owner.owningScreen)
    }

    private func refreshUndoState() {
        guard let view = ownerPanel?.overlayView else { return }
        state.canUndo = view.canvasUndoManager.canUndo
        state.canRedo = view.canvasUndoManager.canRedo
        state.hasAnnotation = !view.annotations.isEmpty
        state.isOCRAnalyzing = view.isOCRAnalyzing
    }

    // MARK: - Export

    private func renderFinalImage() -> NSImage? {
        guard let owner = ownerPanel,
              let frame = frozenFrames[owner.owningScreen] else { return nil }
        let view = owner.overlayView
        let sel = view.selection
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let scaleX = CGFloat(frame.width) / view.bounds.width
        let scaleY = CGFloat(frame.height) / view.bounds.height
        let pxRect = CGRect(
            x: sel.origin.x * scaleX,
            y: (view.bounds.height - sel.maxY) * scaleY,
            width: sel.width * scaleX,
            height: sel.height * scaleY
        )
        guard let cropped = frame.cropping(to: pxRect) else { return nil }
        return AnnotationRenderer.render(base: cropped, annotations: view.annotations, pointSize: sel.size)
    }

    private func confirmAndCopy() {
        guard let img = renderFinalImage() else { cancel(); return }
        exporter.copyToPasteboard(img)
        dismissAll()
    }

    private func saveAndDismiss() {
        guard let img = renderFinalImage() else { cancel(); return }
        // Overlay panels live at CGShieldingWindowLevel — above the NSOpenPanel.
        // Temporarily drop them to .normal (same pattern as cancel()) so the folder
        // picker is visible and interactive, then restore if the user cancels.
        let savedLevels: [(NSPanel, NSWindow.Level)] = overlayPanels.map { ($0, $0.level) }
        let savedToolbarLevel = toolbarPanel?.level
        for p in overlayPanels { p.level = .normal }
        toolbarPanel?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        exporter.saveWithFolderPicker(img, from: nil) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.dismissAll()
            } else {
                // User cancelled the picker — restore overlay panels and stay in editor.
                for (p, lvl) in savedLevels { p.level = lvl }
                if let lvl = savedToolbarLevel { self.toolbarPanel?.level = lvl }
            }
        }
    }

    func cancel() {
        if let view = ownerPanel?.overlayView, !view.annotations.isEmpty {
            // Overlay panels live at CGShieldingWindowLevel — above modal alerts.
            // Temporarily drop them to .normal so the alert is interactive,
            // then restore on dismiss.
            let savedLevels: [(NSPanel, NSWindow.Level)] = overlayPanels.map { ($0, $0.level) }
            let savedToolbarLevel = toolbarPanel?.level
            for p in overlayPanels { p.level = .normal }
            toolbarPanel?.level = .normal

            let alert = NSAlert()
            alert.messageText = String(localized: "Discard annotations?")
            alert.addButton(withTitle: String(localized: "Discard"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
            let response = alert.runModal()

            if response != .alertFirstButtonReturn {
                // User cancelled — restore overlay panels and stay in editor.
                for (p, lvl) in savedLevels { p.level = lvl }
                if let lvl = savedToolbarLevel { toolbarPanel?.level = lvl }
                return
            }
        }
        dismissAll()
    }

    private func dismissAll() {
        toolbarPanel?.dismiss()
        toolbarPanel = nil
        for p in overlayPanels { p.dismiss() }
        overlayPanels.removeAll()
        ownerPanel = nil
        frozenFrames.removeAll()
        cancellables.removeAll()
        isCapturing = false
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Permission

    private func handlePermissionDenied() {
        let now = CACurrentMediaTime()
        if now - lastPermissionAlertAt < permissionAlertCooldown { return }
        lastPermissionAlertAt = now

        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Recording Permission Required")
        alert.informativeText = String(localized: "KeyMic needs Screen Recording permission to take screenshots. Open System Settings → Privacy & Security → Screen Recording.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
            guard CGPreflightScreenCaptureAccess() else { return }
            timer.invalidate()
            self.permissionPollTimer = nil
            self.start()
        }
    }
}

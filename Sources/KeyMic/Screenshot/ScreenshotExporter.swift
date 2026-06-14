import Cocoa
import UniformTypeIdentifiers

final class ScreenshotExporter {
    private func pngAndTiff(_ image: NSImage) -> (png: Data, tiff: Data)? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, tiff)
    }

    func copyToPasteboard(_ image: NSImage) {
        guard let data = pngAndTiff(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data.png, forType: .png)
        pb.setData(data.tiff, forType: .tiff)
    }

    func saveWithFolderPicker(_ image: NSImage, from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Save")
        panel.message = String(localized: "Choose a folder to save the screenshot")

        let lastDir = UserDefaults.standard.url(forKey: "lastScreenshotSaveDir")
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        panel.directoryURL = lastDir

        let host = window ?? NSApp.mainWindow
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let dir = panel.url else {
                completion(false); return
            }
            UserDefaults.standard.set(dir, forKey: "lastScreenshotSaveDir")
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss.SSS"
            let filename = "KeyMic-\(fmt.string(from: Date())).png"
            let url = dir.appendingPathComponent(filename)
            self.writePNG(image, to: url, completion: completion)
        }
        if let host = host {
            panel.beginSheetModal(for: host, completionHandler: handler)
        } else {
            // No host window (LSUIElement): make sure the picker floats above the
            // screenshot overlay panels (dropped to .normal by the caller).
            panel.level = .floating
            panel.begin(completionHandler: handler)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func showShareSheet(_ image: NSImage, from view: NSView, relativeTo rect: NSRect) {
        guard let data = pngAndTiff(image) else { return }
        let item = NSItemProvider(item: data.png as NSData, typeIdentifier: UTType.png.identifier)
        let picker = NSSharingServicePicker(items: [item])
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private func writePNG(_ image: NSImage, to url: URL, completion: @escaping (Bool) -> Void) {
        guard let png = pngAndTiff(image)?.png else {
            completion(false); return
        }
        do {
            try png.write(to: url)
            completion(true)
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = String(localized: "Save Failed")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                completion(false)
            }
        }
    }
}

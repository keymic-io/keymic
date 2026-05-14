import Cocoa
import UniformTypeIdentifiers

final class ScreenshotExporter {
    func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
    }

    func saveWithFolderPicker(_ image: NSImage, from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Save"
        panel.message = "Choose a folder to save the screenshot"

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
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let filename = "KeyMic-\(fmt.string(from: Date())).png"
            let url = dir.appendingPathComponent(filename)
            self.writePNG(image, to: url, completion: completion)
        }
        if let host = host {
            panel.beginSheetModal(for: host, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func showShareSheet(_ image: NSImage, from view: NSView, relativeTo rect: NSRect) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let item = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let picker = NSSharingServicePicker(items: [item])
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private func writePNG(_ image: NSImage, to url: URL, completion: @escaping (Bool) -> Void) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            completion(false); return
        }
        do {
            try png.write(to: url)
            completion(true)
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Save Failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                completion(false)
            }
        }
    }
}

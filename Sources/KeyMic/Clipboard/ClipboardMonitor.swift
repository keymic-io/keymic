import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os

@MainActor
final class ClipboardMonitor {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardMonitor")
    typealias SourceAppProvider = () -> (bundleID: String?, name: String?)

    private let pasteboard: PasteboardReading
    private let store: ClipboardStore
    private let ownBundleID: String
    private let sourceAppProvider: SourceAppProvider
    private let ignoreConfidential: () -> Bool
    private let isEnabled: () -> Bool

    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private var timer: DispatchSourceTimer?

    init(
        pasteboard: PasteboardReading,
        store: ClipboardStore,
        ownBundleID: String,
        sourceAppProvider: @escaping SourceAppProvider,
        ignoreConfidential: @escaping () -> Bool,
        isEnabled: @escaping () -> Bool
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.ownBundleID = ownBundleID
        self.sourceAppProvider = sourceAppProvider
        self.ignoreConfidential = ignoreConfidential
        self.isEnabled = isEnabled
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Records `changeCount` as KeyMic's own write so the next tick observing that
    /// exact changeCount is skipped.  Counter-based — no content matching needed.
    func markIgnoredChangeCount(_ changeCount: Int) {
        ignoredChangeCount = changeCount
    }

    func tickForTesting() { tick() }

    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Counter-based ignore: skip the tick whose changeCount we just wrote.
        if let ignored = ignoredChangeCount, ignored == current {
            ignoredChangeCount = nil
            return
        }

        guard isEnabled() else {
            ignoredChangeCount = nil
            return
        }

        let types = Set(pasteboard.types())

        if ignoreConfidential(), !types.isDisjoint(with: ConfidentialClipboardType.all) {
            return
        }

        let source = sourceAppProvider()
        if let bundleID = source.bundleID, bundleID == ownBundleID {
            return
        }

        if types.contains("public.png") || types.contains("public.tiff") {
            captureImage(types: types, source: source)
        } else if types.contains("public.file-url") || !pasteboard.fileURLs().isEmpty {
            captureFile(source: source)
        } else if types.contains("public.html") || types.contains("public.rtf") {
            captureRichText(types: types, source: source)
        } else {
            capturePlainText(source: source)
        }
    }

    private func captureImage(types: Set<String>, source: (bundleID: String?, name: String?)) {
        let (preferType, format): (String, ImageFormat) =
            types.contains("public.png")
            ? ("public.png", .png)
            : ("public.tiff", .tiff)
        guard let data = pasteboard.data(forType: preferType) else { return }

        // Dimension decode + SHA-256 + the (up to 20 MB) atomic disk write are heavy
        // enough to stall the main thread — and the event tap lives on its run loop,
        // so a stall briefly drops every global hotkey. Do that work off-main, then
        // commit to SwiftData back on the main actor (mainContext is main-affine).
        let store = self.store
        let src = source
        Task.detached(priority: .utility) {
            let (w, h) = Self.decodeImageDimensions(data: data)
            guard let prepared = store.prepareImage(data: data, format: format, width: w, height: h) else { return }
            await MainActor.run {
                store.commitImage(prepared, sourceBundleID: src.bundleID, sourceAppName: src.name)
            }
        }
    }

    private func captureFile(source: (bundleID: String?, name: String?)) {
        let urls = pasteboard.fileURLs()
        guard let first = urls.first else { return }
        store.add(fileURL: first, sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    private func captureRichText(types: Set<String>, source: (bundleID: String?, name: String?)) {
        let (typeKey, format): (String, RichTextFormat) =
            types.contains("public.html")
            ? ("public.html", .html)
            : ("public.rtf", .rtf)
        guard let blob = pasteboard.data(forType: typeKey) else { return }
        let plain = pasteboard.string() ?? ""
        store.add(
            richText: blob, format: format, plainText: plain,
            sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    private func capturePlainText(source: (bundleID: String?, name: String?)) {
        guard let text = pasteboard.string(),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        store.add(text: text, sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    nonisolated private static func decodeImageDimensions(data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else {
            return (0, 0)
        }
        return (w, h)
    }
}

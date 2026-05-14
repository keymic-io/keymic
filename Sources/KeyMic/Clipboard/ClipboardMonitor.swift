import AppKit
import CoreGraphics
import CryptoKit
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
    private var ignoredToken: String?
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

    /// Marks `token` as KeyMic's own write so the next observed change matching it is skipped.
    /// Token semantics: text = content string, image = SHA-256 hex, file = absolute path,
    /// richText = plain-text fallback.
    func markIgnored(token: String) {
        ignoredToken = token
    }

    /// Back-compat shim — `ClipboardController.markPasteboardWrite` still uses the text overload.
    func markIgnored(text: String) {
        markIgnored(token: text)
    }

    func tickForTesting() { tick() }

    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isEnabled() else {
            ignoredToken = nil
            return
        }

        if ignoreConfidential() {
            let types = Set(pasteboard.types())
            if !types.isDisjoint(with: ConfidentialClipboardType.all) {
                ignoredToken = nil
                return
            }
        }

        let source = sourceAppProvider()
        if let bundleID = source.bundleID, bundleID == ownBundleID {
            ignoredToken = nil
            return
        }

        let types = Set(pasteboard.types())

        // Priority 1: image
        if types.contains("public.png") || types.contains("public.tiff") {
            captureImage(types: types, source: source)
            return
        }
        // Priority 2: file URL
        if types.contains("public.file-url") || !pasteboard.fileURLs().isEmpty {
            captureFile(source: source)
            return
        }
        // Priority 3: rich text
        if types.contains("public.html") || types.contains("public.rtf") {
            captureRichText(types: types, source: source)
            return
        }
        // Priority 4: plain text (existing path)
        capturePlainText(source: source)
    }

    private func captureImage(types: Set<String>, source: (bundleID: String?, name: String?)) {
        let (preferType, format): (String, ImageFormat) =
            types.contains("public.png")
            ? ("public.png", .png)
            : ("public.tiff", .tiff)
        guard let data = pasteboard.data(forType: preferType) else {
            ignoredToken = nil
            return
        }

        let hash = data.sha256Hex
        if shouldDropMatchingIgnored(hash) { return }

        let (w, h) = decodeImageDimensions(data: data)
        store.add(
            image: data, format: format, width: w, height: h,
            sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    private func captureFile(source: (bundleID: String?, name: String?)) {
        let urls = pasteboard.fileURLs()
        guard let first = urls.first else {
            ignoredToken = nil
            return
        }
        if shouldDropMatchingIgnored(first.path) { return }
        store.add(fileURL: first, sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    private func captureRichText(types: Set<String>, source: (bundleID: String?, name: String?)) {
        let (typeKey, format): (String, RichTextFormat) =
            types.contains("public.html")
            ? ("public.html", .html)
            : ("public.rtf", .rtf)
        guard let blob = pasteboard.data(forType: typeKey) else {
            ignoredToken = nil
            return
        }
        let plain = pasteboard.string() ?? ""
        if shouldDropMatchingIgnored(plain) { return }
        store.add(
            richText: blob, format: format, plainText: plain,
            sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    private func capturePlainText(source: (bundleID: String?, name: String?)) {
        guard let text = pasteboard.string(),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            ignoredToken = nil
            return
        }
        if shouldDropMatchingIgnored(text) { return }
        store.add(text: text, sourceBundleID: source.bundleID, sourceAppName: source.name)
    }

    private func shouldDropMatchingIgnored(_ token: String) -> Bool {
        if let ignored = ignoredToken {
            ignoredToken = nil
            if ignored == token { return true }
        }
        return false
    }

    private func decodeImageDimensions(data: Data) -> (Int, Int) {
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

extension Data {
    /// Lowercase SHA-256 hex digest. Must produce the same string as
    /// `ClipboardStore.add(image:)` so markIgnored tokens compare equal.
    fileprivate var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

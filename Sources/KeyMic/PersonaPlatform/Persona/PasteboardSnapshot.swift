import AppKit
import CryptoKit
import Foundation

/// Save / restore the contents of an NSPasteboard plus a `markIgnored` token
/// that matches the rule ClipboardMonitor.tick() would compute for the same data.
enum PasteboardSnapshot {
    struct Snapshot {
        let items: [[String: Data]]
        let plainText: String?
        let imageHashHex: String?
        let filePath: String?

        /// Token to feed into ClipboardMonitor.markIgnored AFTER restoring this
        /// snapshot, so the resulting changeCount tick is dropped from history.
        /// Mirrors ClipboardMonitor's branch order: image → file → text.
        var ignoredToken: String? {
            if let hash = imageHashHex { return hash }
            if let path = filePath { return path }
            return plainText
        }
    }

    static func capture(_ pasteboard: NSPasteboard) -> Snapshot {
        var serialized: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            if !dict.isEmpty { serialized.append(dict) }
        }

        let plainText = pasteboard.string(forType: .string)
        let availableTypes = Set((pasteboard.types ?? []).map(\.rawValue))

        var imageHashHex: String?
        var filePath: String?

        if availableTypes.contains("public.png") {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) {
                imageHashHex = data.snapshotSHA256Hex
            }
        } else if availableTypes.contains("public.tiff") {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.tiff")) {
                imageHashHex = data.snapshotSHA256Hex
            }
        } else if availableTypes.contains("public.file-url") {
            if let urlString = pasteboard.string(
                forType: NSPasteboard.PasteboardType("public.file-url")),
                let url = URL(string: urlString)
            {
                filePath = url.path
            }
        }

        return Snapshot(
            items: serialized,
            plainText: plainText,
            imageHashHex: imageHashHex,
            filePath: filePath
        )
    }

    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { dict in
            let item = NSPasteboardItem()
            for (typeKey, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeKey))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

extension Data {
    /// Must produce the same string ClipboardMonitor computes for an image
    /// payload, so markIgnored tokens compare equal. See ClipboardMonitor.swift.
    fileprivate var snapshotSHA256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

/// Format of the bytes stored in `ClipboardItem.richBlob`. Drives the
/// pasteboard type used on paste-back.
enum RichTextFormat: String, Codable {
    case html
    case rtf

    /// NSPasteboard.PasteboardType raw value matching the format.
    var pasteboardType: String {
        switch self {
        case .html: return "public.html"
        case .rtf: return "public.rtf"
        }
    }
}

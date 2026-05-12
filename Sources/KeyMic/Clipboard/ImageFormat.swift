import Foundation

/// Image encoding used both when writing the cache file and when paste-back
/// writes bytes to NSPasteboard.
enum ImageFormat: String, Codable {
    case png
    case tiff

    var fileExtension: String { rawValue }

    /// NSPasteboard.PasteboardType raw value matching the format.
    var pasteboardType: String {
        switch self {
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        }
    }
}

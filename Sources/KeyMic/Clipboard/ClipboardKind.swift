import Foundation

enum ClipboardKind: String, Codable {
    case plain
    case url
    case filePath
    case color
    case secret
    case codeJSON
    case codeXML
    case codeHTML
    case image
    case file
    case richText

    var iconSymbolName: String? {
        switch self {
        case .plain: return nil
        case .url: return "link"
        case .filePath: return "folder"
        case .color: return "paintpalette"
        case .secret: return "key.fill"
        case .codeJSON: return "curlybraces"
        case .codeXML: return "chevron.left.forwardslash.chevron.right"
        case .codeHTML: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .file: return "doc"
        case .richText: return "doc.richtext"
        }
    }
}

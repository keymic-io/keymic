import Foundation
import SwiftData

@Model
final class ClipboardItem {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date
    var sourceBundleID: String?
    var sourceAppName: String?
    var kindRaw: String
    var isPinned: Bool = false
    var pinnedAt: Date? = nil

    var kind: ClipboardKind {
        get { ClipboardKind(rawValue: kindRaw) ?? .plain }
        set { kindRaw = newValue.rawValue }
    }

    init(
        text: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = Date(),
        kind: ClipboardKind = .plain
    ) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.kindRaw = kind.rawValue
        self.isPinned = false
        self.pinnedAt = nil
    }
}

extension ClipboardItem {
    /// Single-line preview (max 80 chars, newlines replaced).
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ↵ ")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\t", with: "    ")
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }

    var displayPreview: String {
        switch kind {
        case .secret: return Self.maskSecret(preview)
        default: return preview
        }
    }

    private static func maskSecret(_ raw: String) -> String {
        let single = raw.replacingOccurrences(of: "\n", with: " ")
        guard single.count > 8 else { return String(repeating: "•", count: single.count) }
        return "\(single.prefix(4))••••\(single.suffix(4))"
    }
}

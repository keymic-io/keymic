import SwiftUI

struct HighlightedText: View {
    let source: String
    let query: String

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var attr = AttributedString(source)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attr }

        var searchRange = source.startIndex..<source.endIndex
        while let match = source.range(of: trimmed, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(match, in: attr) {
                attr[attrRange].foregroundColor = .accentColor
                attr[attrRange].font = .body.bold()
            }
            searchRange = match.upperBound..<source.endIndex
        }
        return attr
    }
}

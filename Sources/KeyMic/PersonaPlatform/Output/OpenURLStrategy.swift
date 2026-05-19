import AppKit
import Foundation

enum OpenURLError: Error, Equatable {
    case missingPlaceholder
    case invalidURL
}

final class OpenURLStrategy: OutputStrategyHandler {
    private let template: String
    private let opener: (URL) -> Void

    init(template: String,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.template = template
        self.opener = opener
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        guard template.contains("{query}") else { throw OpenURLError.missingPlaceholder }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let filled = template.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: filled) else { throw OpenURLError.invalidURL }
        await MainActor.run { self.opener(url) }
    }
}

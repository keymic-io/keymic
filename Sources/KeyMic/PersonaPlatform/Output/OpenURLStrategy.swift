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
        // Percent-encode every reserved char so the query value is safe to drop
        // into any template position. `.urlQueryAllowed` keeps `&`/`=`/`?`, which
        // breaks the surrounding URL when text contains them.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#+/"))
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let filled = template.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: filled) else { throw OpenURLError.invalidURL }
        await MainActor.run { self.opener(url) }
    }
}

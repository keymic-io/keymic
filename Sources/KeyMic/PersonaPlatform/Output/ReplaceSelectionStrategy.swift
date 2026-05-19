import Foundation

final class ReplaceSelectionStrategy: OutputStrategyHandler {
    private let writeSelection: (String) throws -> Void
    private let fallback: FocusedTextStrategy

    init(fallback: FocusedTextStrategy,
         writeSelection: @escaping (String) throws -> Void = { try SelectionSource.replaceSelection(with: $0) }) {
        self.writeSelection = writeSelection
        self.fallback = fallback
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        do {
            try writeSelection(text)
        } catch SelectionWriteError.notSettable {
            // Documented fallback to focused-text inject.
            try await fallback.dispatch(text: text, origin: origin, options: options)
        }
    }
}

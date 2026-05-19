import Foundation

protocol OutputStrategyHandler {
    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws
}

struct StrategyOptions {
    let reactivateOrigin: Bool

    static let defaults = StrategyOptions(reactivateOrigin: true)
}

enum OutputError: Error {
    case notSupportedYet
}

final class OutputRouter {
    private let focusedText: OutputStrategyHandler
    private let replaceSelection: OutputStrategyHandler
    private let clipboard: OutputStrategyHandler
    private let openURLFactory: (String) -> OutputStrategyHandler

    init(focusedText: OutputStrategyHandler,
         replaceSelection: OutputStrategyHandler,
         clipboard: OutputStrategyHandler,
         openURLFactory: @escaping (String) -> OutputStrategyHandler) {
        self.focusedText = focusedText
        self.replaceSelection = replaceSelection
        self.clipboard = clipboard
        self.openURLFactory = openURLFactory
    }

    func dispatch(_ strategy: OutputStrategy,
                  text: String,
                  origin: String?,
                  options: StrategyOptions = .defaults) async throws {
        switch strategy {
        case .replaceFocusedText:
            try await focusedText.dispatch(text: text, origin: origin, options: options)
        case .replaceSelection:
            try await replaceSelection.dispatch(text: text, origin: origin, options: options)
        case .clipboard:
            try await clipboard.dispatch(text: text, origin: origin, options: options)
        case .openURL(let template):
            let handler = openURLFactory(template)
            try await handler.dispatch(text: text, origin: origin, options: options)
        case .runShell, .iTermPane:
            // P3 plan implements these. Built-in personas do not use them.
            throw OutputError.notSupportedYet
        }
    }
}

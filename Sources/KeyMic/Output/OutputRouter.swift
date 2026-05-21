import AppKit
import Foundation

enum InjectionStrategy: Codable, Equatable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL(template: String)
    case runShell(commandTemplate: String)
    case writeToITermPane(paneIndex: Int)
}

/// What gets routed. Built by AppDelegate.finishTranscription (or any future consumer).
struct PersonaOutput {
    let text: String
    let strategy: InjectionStrategy
    /// Frontmost app at the time the persona was triggered. Router restores focus
    /// to this app before injecting where applicable.
    let originatingApp: NSRunningApplication?
    /// Optional context payload for templating (openURL placeholders).
    let context: PersonaContext?
}

enum RouteResult: Equatable {
    case injected
    case fellBackToClipboard(reason: FallbackReason)
    case userCancelled
    case failed(message: String)
}

enum FallbackReason: String, Equatable {
    case selectionNotEditable
    case noFocusedElement
    case axPermissionMissing
    case strategyNotImplemented
}

enum OutputRouterError: Error {
    case invalidURLTemplate(String)
    case unsupportedStrategy(InjectionStrategy)
}

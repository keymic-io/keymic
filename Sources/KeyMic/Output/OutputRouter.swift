import Foundation

enum InjectionStrategy: Codable, Equatable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL(template: String)
    case runShell(commandTemplate: String)
    case writeToITermPane(paneIndex: Int)
}

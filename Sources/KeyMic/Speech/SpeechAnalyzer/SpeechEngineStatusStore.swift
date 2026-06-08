import Foundation
import Combine

/// Shared, observable holder for the currently-resolved speech engine, so the
/// Settings voice tab can display which engine is live. AppDelegate calls
/// `update(_:)` after every engine decision. Pure Swift — not behind #if.
@MainActor
final class SpeechEngineStatusStore: ObservableObject {
    static let shared = SpeechEngineStatusStore()
    @Published private(set) var status: SpeechEngineStatus = .sfSpeechRecognizer
    private init() {}

    func update(_ newStatus: SpeechEngineStatus) {
        if status != newStatus { status = newStatus }
    }
}

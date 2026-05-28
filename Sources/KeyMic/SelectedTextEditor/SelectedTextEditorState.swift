import AppKit
import Foundation
import Observation

/// Observable UI state for the Selected Text Editor panel.
/// Lives for the lifetime of the controller; reset() called on every open().
@Observable
@MainActor
final class SelectedTextEditorState {
    var selectionPreview: String = ""
    var selectionFullText: String = ""
    var instructionText: String = ""
    var selectedAction: EditorAction = .freeForm
    var isRecording: Bool = false
    var isRunning: Bool = false
    var audioLevel: Float = 0.0
    var result: String?
    var errorMessage: String?
    var routeResult: RouteResult?
    var statusMessage: String?
    var originatingApp: NSRunningApplication?

    func reset() {
        selectionPreview = ""
        selectionFullText = ""
        instructionText = ""
        selectedAction = .freeForm
        isRecording = false
        isRunning = false
        audioLevel = 0.0
        result = nil
        errorMessage = nil
        routeResult = nil
        statusMessage = nil
        originatingApp = nil
    }
}

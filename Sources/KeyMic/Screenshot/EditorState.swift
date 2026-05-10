import SwiftUI
import Combine

/// Bridges the SwiftUI floating toolbar to the AppKit overlay view.
final class EditorState: ObservableObject {
    @Published var selectedTool: AnnotationTool = .select
    @Published var selectedColor: Color = .red
    @Published var lineWidth: CGFloat = 3
    @Published var fontSize: CGFloat = 18
    @Published var dropShadowEnabled: Bool = false

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var hasAnnotation: Bool = false
    @Published var isOCRAnalyzing: Bool = false

    var undoAction: (() -> Void)?
    var redoAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var saveAction: (() -> Void)?
    var confirmAction: (() -> Void)?
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}
extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}

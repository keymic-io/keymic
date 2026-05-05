import SwiftUI
import Combine

final class EditorState: ObservableObject {
    @Published var selectedTool: AnnotationTool = .select
    @Published var selectedColor: Color = .red
    @Published var lineWidth: CGFloat = 3
    @Published var fontSize: CGFloat = 18
    @Published var dropShadowEnabled: Bool = false

    // Canvas-driven (read-only from toolbar's POV)
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var hasSelection: Bool = false

    // Action callbacks — set by EditorWindowController, invoked by toolbar buttons
    var undoAction: (() -> Void)?
    var redoAction: (() -> Void)?
    var clearAction: (() -> Void)?
    var copyAction: (() -> Void)?
    var saveAction: (() -> Void)?
    /// Share anchor: the controller provides the anchor NSView and its bounds rect.
    /// Pragmatic v1: toolbar passes NSApp.keyWindow?.contentView and .zero as anchor —
    /// the share picker will appear near the window. The controller can override later.
    var shareAction: ((NSView, NSRect) -> Void)?
}

// MARK: - Color Conversion Helpers

extension Color {
    var nsColor: NSColor {
        NSColor(self)  // macOS 12+
    }
}

extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}

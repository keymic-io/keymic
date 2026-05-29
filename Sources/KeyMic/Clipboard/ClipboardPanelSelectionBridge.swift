import AppKit
import Foundation
import Observation

/// Carries clipboard-panel multi-selection state from the SwiftUI view back to
/// `ClipboardController`, so the global ⌥L hotkey can read current selection
/// without poking into the view. Owned by `ClipboardController`.
@MainActor
@Observable
final class ClipboardPanelSelectionBridge {
    /// IDs of currently-selected ClipboardItems (multi-select aware).
    var selectedIDs: Set<UUID> = []

    /// Anchor for shift-click range selection.
    var lastClickedID: UUID?

    /// Snapshot used by global hotkey: returns selection in *current visual order*
    /// — the view writes this whenever its filtered list changes.
    var visibleOrderedIDs: [UUID] = []

    /// Single-select consumer helper: nil unless exactly one item is selected.
    var primarySelection: UUID? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    /// Returns the selection in visual order; falls back to empty when nothing selected.
    func orderedSelection() -> [UUID] {
        visibleOrderedIDs.filter { selectedIDs.contains($0) }
    }

    func reset() {
        selectedIDs.removeAll()
        lastClickedID = nil
        visibleOrderedIDs.removeAll()
    }
}

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

    /// Selection order for checkbox-ticked items.
    var selectedOrder: [UUID] = []

    /// Focused row for keyboard navigation / hover.
    var focusedID: UUID?

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
        selectedOrder.filter { selectedIDs.contains($0) && visibleOrderedIDs.contains($0) }
    }

    func focus(_ id: UUID?) {
        focusedID = id
        if id != nil {
            lastClickedID = id
        }
    }

    func setOnlySelection(_ id: UUID?) {
        guard let id else {
            clearSelection()
            return
        }
        selectedIDs = [id]
        selectedOrder = [id]
        focusedID = id
        lastClickedID = id
    }

    func appendSelection(_ id: UUID) {
        if selectedIDs.insert(id).inserted {
            selectedOrder.append(id)
        }
        focusedID = id
        lastClickedID = id
    }

    func removeSelection(_ id: UUID) {
        selectedIDs.remove(id)
        selectedOrder.removeAll { $0 == id }
        if focusedID == id {
            focusedID = nil
        }
        if lastClickedID == id {
            lastClickedID = focusedID ?? selectedOrder.last
        }
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            removeSelection(id)
        } else {
            appendSelection(id)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
        selectedOrder.removeAll()
    }

    func pruneVisibleState() {
        let visibleSet = Set(visibleOrderedIDs)
        selectedIDs = selectedIDs.intersection(visibleSet)
        selectedOrder.removeAll { !visibleSet.contains($0) || !selectedIDs.contains($0) }
        if let focusedID, !visibleSet.contains(focusedID) {
            self.focusedID = visibleOrderedIDs.first
        }
        if let lastClickedID, !visibleSet.contains(lastClickedID) {
            self.lastClickedID = focusedID ?? selectedOrder.last
        }
    }

    func reset() {
        clearSelection()
        focusedID = nil
        lastClickedID = nil
        visibleOrderedIDs.removeAll()
    }
}

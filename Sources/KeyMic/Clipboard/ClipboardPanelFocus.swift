import Foundation
import Observation

enum PanelTab { case clipboard, vault }

@Observable
final class ClipboardPanelFocus {
    var requestID = 0
    var quickPasteRequestID = 0
    var quickPasteIndex = 0
    var pinnedQuickPasteRequestID = 0
    var pinnedQuickPasteIndex = 0
    var togglePinRequestID = 0
    /// Bumped to move the highlight by `moveSelectionDelta` rows — used by the
    /// hold-modifier switcher gesture, whose taps are swallowed by the CGEvent
    /// tap and so never reach the view's local key monitor.
    var moveSelectionRequestID = 0
    var moveSelectionDelta = 0
    var initialTab: PanelTab = .clipboard
    var tabRequestID = 0
    var currentTab: PanelTab = .clipboard
    /// Section sizes of the currently filtered clipboard list, mirrored by
    /// `ClipboardHistoryView.refreshFiltered` so `ClipboardPanel.sendEvent` can tell
    /// whether an ⌥-shortcut has a target while the search field is being typed in.
    var visiblePinnedCount = 0
    var visibleHistoryCount = 0
}

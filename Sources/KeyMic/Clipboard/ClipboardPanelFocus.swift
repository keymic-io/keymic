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
    var initialTab: PanelTab = .clipboard
    var tabRequestID = 0
    var currentTab: PanelTab = .clipboard
}

import Foundation

enum ClipboardPanelPosition: String, CaseIterable {
    case followCursor
    case screenCenter
}

enum ClipboardPreferences {
    static let enabledKey = "clipboardEnabled"
    static let maxHistoryKey = "clipboardMaxHistory"
    static let ignoreConfidentialKey = "clipboardIgnoreConfidential"
    static let panelPositionKey = "clipboardPanelPosition"

    static let defaultEnabled = true
    static let defaultMaxHistory = 500
    static let defaultIgnoreConfidential = true
    static let defaultPanelPosition: ClipboardPanelPosition = .followCursor
    static let allowedHistorySizes = [50, 100, 200, 500]

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static var maxHistory: Int {
        (UserDefaults.standard.object(forKey: maxHistoryKey) as? Int) ?? defaultMaxHistory
    }

    static var ignoreConfidential: Bool {
        UserDefaults.standard.object(forKey: ignoreConfidentialKey) as? Bool ?? defaultIgnoreConfidential
    }

    static var panelPosition: ClipboardPanelPosition {
        let raw = UserDefaults.standard.string(forKey: panelPositionKey)
        return raw.flatMap(ClipboardPanelPosition.init(rawValue:)) ?? defaultPanelPosition
    }

    static let cleanupModeKey = "clipboardCleanupMode"
    static let cleanupDaysKey = "clipboardCleanupDays"

    static let defaultCleanupMode: CleanupMode = .count
    static let defaultCleanupDays = 30
    static let allowedCleanupDays = [7, 30, 90, 180]

    static var cleanupMode: CleanupMode {
        let raw = UserDefaults.standard.string(forKey: cleanupModeKey)
        return raw.flatMap(CleanupMode.init(rawValue:)) ?? defaultCleanupMode
    }

    static var cleanupDays: Int {
        (UserDefaults.standard.object(forKey: cleanupDaysKey) as? Int) ?? defaultCleanupDays
    }
}

import Foundation

enum HotkeyPreferences {
    static let enabledKey = "hotkeysEnabled"
    static let defaultEnabled = true

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

import Foundation

/// Feature groups for the global tips catalog. Each app pillar contributes
/// its own tips and chooses a display surface (panel footer, settings, …).
enum TipFeature: String, CaseIterable {
    case clipboardHistory
    case voice
    case keyMapping
    case screenshot
    case vault
}

struct AppTip: Identifiable {
    let id: String
    let feature: TipFeature
    /// Tips for features that have not shipped yet stay disabled and are
    /// skipped by rotation until the feature lands.
    let isEnabled: Bool
    /// Resolved at render time so placeholders (current hotkey, …) reflect
    /// the user's live configuration.
    let text: () -> String

    init(id: String, feature: TipFeature, isEnabled: Bool = true, text: @escaping () -> String) {
        self.id = id
        self.feature = feature
        self.isEnabled = isEnabled
        self.text = text
    }
}

enum TipsCatalog {
    /// Injected from AppDelegate at launch; the default keeps this file free
    /// of hotkey-store dependencies so the standalone test compiles it alone.
    static var clipboardPanelHotkeyDisplay: () -> String = { "⌥V" }

    static let all: [AppTip] = [
        AppTip(id: "clipboard.returnPastesFirst", feature: .clipboardHistory) {
            String(localized: "Press ↩ to paste the first item right away.")
        },
        AppTip(id: "clipboard.quickPaste", feature: .clipboardHistory) {
            String(localized: "Press ⌥1–⌥0 to paste one of the first ten items.")
        },
        AppTip(id: "clipboard.spaceMultiPaste", feature: .clipboardHistory) {
            String(localized: "Use ↑↓ + Space to select multiple items to paste.")
        },
        AppTip(id: "clipboard.togglePin", feature: .clipboardHistory) {
            String(localized: "Press ⌥P to pin or unpin the highlighted item.")
        },
        // Hold-modifier switcher gesture (Cmd+Tab style).
        AppTip(id: "clipboard.hotkeyFocusesNext", feature: .clipboardHistory) {
            String(localized: "Press \(clipboardPanelHotkeyDisplay()) again to move focus to the next item.")
        },
        AppTip(id: "clipboard.switcherCommit", feature: .clipboardHistory) {
            String(localized: "Release the modifier to paste the highlighted item and close.")
        },
    ]

    static func tips(for feature: TipFeature) -> [AppTip] {
        all.filter { $0.feature == feature && $0.isEnabled }
    }

    /// Wrap-around index used by `nextTip`; separated for testability.
    static func rotationPosition(counter: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let mod = counter % count
        return mod >= 0 ? mod : mod + count
    }

    /// Returns the tip to show and advances the per-feature rotation counter,
    /// so each panel open surfaces the next tip in the group.
    static func nextTip(for feature: TipFeature, defaults: UserDefaults = .standard) -> AppTip? {
        let tips = tips(for: feature)
        guard !tips.isEmpty else { return nil }
        let key = "tips.rotation.\(feature.rawValue)"
        let counter = defaults.integer(forKey: key)
        defaults.set(counter &+ 1, forKey: key)
        return tips[rotationPosition(counter: counter, count: tips.count)]
    }
}

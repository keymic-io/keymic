import Foundation

@main
struct AppTipsTestRunner {
    static func main() {
        // Catalog integrity
        let ids = TipsCatalog.all.map(\.id)
        expect(Set(ids).count == ids.count, "tip ids must be unique")
        expect(!TipsCatalog.tips(for: .clipboardHistory).isEmpty,
               "clipboard history group should have enabled tips")
        expect(TipsCatalog.tips(for: .clipboardHistory).allSatisfy(\.isEnabled),
               "tips(for:) must exclude disabled tips")
        expect(TipsCatalog.all.contains { $0.id == "clipboard.hotkeyFocusesNext" && $0.isEnabled },
               "the hold-modifier switcher tip should be enabled now that the gesture ships")
        expect(TipsCatalog.all.contains { $0.id == "clipboard.switcherCommit" },
               "the release-to-paste tip should exist")

        // Rotation position wrap-around
        expect(TipsCatalog.rotationPosition(counter: 0, count: 3) == 0, "counter 0 maps to first tip")
        expect(TipsCatalog.rotationPosition(counter: 4, count: 3) == 1, "counter wraps around the group")
        expect(TipsCatalog.rotationPosition(counter: -1, count: 3) == 2, "negative counter stays in range")
        expect(TipsCatalog.rotationPosition(counter: 7, count: 0) == 0, "empty group does not crash")

        // nextTip advances the per-feature counter
        let suite = "io.keymic.tests.app-tips"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let enabled = TipsCatalog.tips(for: .clipboardHistory)
        var seen: [String] = []
        for _ in 0..<(enabled.count * 2) {
            seen.append(TipsCatalog.nextTip(for: .clipboardHistory, defaults: defaults)!.id)
        }
        expect(Array(seen.prefix(enabled.count)) == enabled.map(\.id),
               "nextTip should walk the group in order")
        expect(Array(seen.suffix(enabled.count)) == enabled.map(\.id),
               "nextTip should cycle back after exhausting the group")
        defaults.removePersistentDomain(forName: suite)

        // Hotkey placeholder resolves through the injected provider at render time
        TipsCatalog.clipboardPanelHotkeyDisplay = { "⌃⌘T" }
        let hotkeyTip = TipsCatalog.all.first { $0.id == "clipboard.hotkeyFocusesNext" }!
        expect(hotkeyTip.text().contains("⌃⌘T"),
               "hotkey tip must interpolate the current hotkey display string")

        print("AppTipsTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

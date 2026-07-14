import CoreGraphics
import Foundation

@main
struct HotkeyRegistryTestRunner {
    static func main() {
        let r = HotkeyRegistry.shared
        // Clear any existing registrations from app startup
        r.unregister(owner: .voiceTrigger)
        r.unregister(owner: .clipboardPanel)

        let altQ = HotkeyConfig.parse("alt+q")!
        let altW = HotkeyConfig.parse("alt+w")!
        let altV = HotkeyConfig.parse("alt+v")!

        // empty registry: no conflicts
        expect(r.conflicts(for: altQ, excluding: nil as HotkeyRegistry.Owner?).isEmpty, "empty registry has no conflicts")

        // register clipboard panel hotkey
        r.register(altV, owner: .clipboardPanel, purpose: "Open clipboard panel")
        let c = r.conflicts(for: altV, excluding: nil as HotkeyRegistry.Owner?)
        expect(c.count == 1, "registered hotkey reports 1 conflict")
        expect(c[0].purpose == "Open clipboard panel", "conflict carries purpose label")

        // excluding self → no self-conflict
        let cExcluded = r.conflicts(for: altV, excluding: .clipboardPanel)
        expect(cExcluded.isEmpty, "excluding owner hides self")

        // register two persona hotkeys
        r.register(altQ, owner: .persona(id: "p1"), purpose: "Persona: Default")
        r.register(altW, owner: .persona(id: "p2"), purpose: "Persona: Translate")
        expect(r.all().count == 3, "three entries registered")

        // unregister by owner
        r.unregister(owner: .persona(id: "p1"))
        expect(r.all().count == 2, "unregister drops one entry")
        expect(r.conflicts(for: altQ, excluding: nil as HotkeyRegistry.Owner?).isEmpty, "alt+q free after unregister")

        // re-register same owner replaces (no duplicate)
        r.register(altQ, owner: .persona(id: "p2"), purpose: "Persona: Translate (renamed)")
        expect(r.all().count == 2, "re-register same owner replaces, count unchanged")
        let c2 = r.conflicts(for: altQ, excluding: nil as HotkeyRegistry.Owner?)
        expect(c2.count == 1 && c2[0].purpose.contains("renamed"), "re-register overwrites purpose")

        // Cleanup: unregister test entries so shared registry is clean for app use
        r.unregister(owner: .clipboardPanel)
        r.unregister(owner: .persona(id: "p2"))

        // --- keyMapping semantics ---
        let r2 = HotkeyRegistry()
        let altQ2 = HotkeyConfig.parse("alt+q")!
        // a remap whose source key is Q (keyCode matches alt+q's key)
        let remapSource = HotkeyConfig(modifiers: [], keyCode: altQ2.keyCode)
        r2.register(remapSource, owner: .keyMapping(id: "m1"), purpose: "Key mapping: Q")
        let kmConflicts = r2.conflicts(for: altQ2, excluding: nil as HotkeyRegistry.Owner?)
        expect(kmConflicts.count == 1, "keyMapping entry conflicts on keyCode regardless of modifiers")
        let otherKey = HotkeyConfig.parse("alt+w")!
        expect(r2.conflicts(for: otherKey, excluding: nil as HotkeyRegistry.Owner?).isEmpty,
               "keyMapping entry does not conflict with different keyCode")

        // --- entriesUsing(keyCode:) ---
        r2.register(altQ2, owner: .persona(id: "p9"), purpose: "Persona: Q user")
        let users = r2.entriesUsing(keyCode: altQ2.keyCode, excluding: .keyMapping(id: "m1"))
        expect(users.count == 1, "entriesUsing finds hotkeys sharing the keyCode, excluding self")
        expect(r2.entriesUsing(keyCode: otherKey.keyCode, excluding: nil as HotkeyRegistry.Owner?)
            .filter { $0.config.keyCode == otherKey.keyCode }.count == 0,
               "entriesUsing empty for unused keyCode")

        print("✅ HotkeyRegistryTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("❌ \(msg)"); exit(1) }
    }
}

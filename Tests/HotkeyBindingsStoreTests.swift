import Foundation

@main
struct HotkeyBindingsStoreTestRunner {
    static func main() {
        let suiteName = "keymic-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HotkeyBindingsStore(defaults: defaults)

        // 默认空
        expect(store.bindings.isEmpty, "default empty")

        // 写入 + 重读
        let b = HotkeyBinding(
            trigger: "ctrl+cmd+c",
            actions: [.typeText("/clear"), .keyPress(keyCode: 0x24, modifiers: 0)]
        )
        store.bindings = [b]

        let store2 = HotkeyBindingsStore(defaults: defaults)
        expect(store2.bindings.count == 1, "round-trip count")
        expect(store2.bindings[0].trigger == "ctrl+cmd+c", "round-trip trigger")
        expect(store2.bindings[0].actions == b.actions, "round-trip actions")

        // 损坏 JSON 容错
        defaults.set(Data([0x00, 0x01]), forKey: "hotkeyBindings")
        let store3 = HotkeyBindingsStore(defaults: defaults)
        expect(store3.bindings.isEmpty, "corrupt data → empty")

        print("HotkeyBindingsStoreTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond {
            FileHandle.standardError.write(("FAIL: " + msg + "\n").data(using: .utf8)!)
            exit(1)
        }
    }
}

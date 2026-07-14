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
        // …且 init 不会立即把空数组写回覆盖原始数据
        expect(
            defaults.data(forKey: "hotkeyBindings") == Data([0x00, 0x01]),
            "decode failure must not overwrite persisted data")

        // 单条损坏 → 跳过该条，其余绑定保留（FailableDecodable 逐元素容错）
        let goodJSON = String(data: try! JSONEncoder().encode([b]), encoding: .utf8)!
        let mixedJSON = goodJSON.dropLast() + #", {"trigger": 42}]"#
        defaults.set(Data(mixedJSON.utf8), forKey: "hotkeyBindings")
        let store4 = HotkeyBindingsStore(defaults: defaults)
        expect(store4.bindings.count == 1, "one bad element skipped, good one kept")
        expect(store4.bindings[0].trigger == "ctrl+cmd+c", "surviving binding intact")
        expect(
            defaults.data(forKey: "hotkeyBindings") == Data(mixedJSON.utf8),
            "partial decode must not write back during init")

        testRegistrySyncOnMutation()
        testReloadRereadsDefaults()

        print("HotkeyBindingsStoreTests passed")
    }

    static func makeDefaults() -> UserDefaults {
        let suiteName = "keymic-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    static func testRegistrySyncOnMutation() {
        let registry = HotkeyRegistry()
        let store = HotkeyBindingsStore(defaults: makeDefaults(), registry: registry)
        let cfg = HotkeyConfig.parse("ctrl+alt+t")!
        let binding = HotkeyBinding(trigger: cfg.encode(), actions: [.typeText("x")], enabled: true)

        store.bindings = [binding]
        expect(
            registry.conflicts(for: cfg, excluding: nil as HotkeyRegistry.Owner?)
                .contains { $0.owner == .hotkeyBinding(id: binding.id) },
            "enabled binding registered")

        var disabled = binding; disabled.enabled = false
        store.bindings = [disabled]
        expect(
            registry.conflicts(for: cfg, excluding: nil as HotkeyRegistry.Owner?).isEmpty,
            "disabled binding unregistered")

        store.bindings = []
        expect(registry.all().isEmpty, "removed binding unregistered")
    }

    static func testReloadRereadsDefaults() {
        let defaults = makeDefaults()
        let registry = HotkeyRegistry()
        let store = HotkeyBindingsStore(defaults: defaults, registry: registry)
        let binding = HotkeyBinding(trigger: "ctrl+alt+t", actions: [.typeText("x")], enabled: true)
        // simulate a Config Sync download writing directly to defaults
        defaults.set(try! JSONEncoder().encode([binding]), forKey: HotkeyBindingsStore.userDefaultsKey)
        store.reload()
        expect(store.bindings.count == 1, "reload picked up synced binding")
        expect(registry.all().count == 1, "reload re-synced registry")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond {
            FileHandle.standardError.write(("FAIL: " + msg + "\n").data(using: .utf8)!)
            exit(1)
        }
    }
}

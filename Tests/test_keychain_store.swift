import Foundation

@main
enum TestKeychainStore {
    static func main() {
        let store = KeychainStore(service: "io.keymic.app.test.keychain")
        store.delete()

        assert(store.read() == nil, "expected nil on empty keychain")
        store.save("mkvc_live_abc")
        assert(store.read() == "mkvc_live_abc", "expected saved value")
        store.save("mkvc_live_def")
        assert(store.read() == "mkvc_live_def", "expected overwritten value")
        store.delete()
        assert(store.read() == nil, "expected nil after delete")

        print("test_keychain_store passed")
    }
}

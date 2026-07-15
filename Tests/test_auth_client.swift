import Foundation

@main
enum TestAuthClient {
    static func main() {
        let url = URL(string: "keymic://callback?code=abc&state=n1")!
        let parsed = AuthClient.parseCallback(url)
        assert(parsed?.code == "abc")
        assert(parsed?.state == "n1")

        let bad = URL(string: "keymic://other?code=abc&state=n1")!
        assert(AuthClient.parseCallback(bad) == nil)

        let m1 = URL(string: "keymic://callback?state=n1")!
        assert(AuthClient.parseCallback(m1) == nil)

        let m2 = URL(string: "keymic://callback?code=abc")!
        assert(AuthClient.parseCallback(m2) == nil)

        let n = AuthClient.generateNonce()
        assert(n.count == 64, "expected 64 hex chars, got \(n.count)")
        assert(n.allSatisfy { c in
            let s = String(c)
            return s >= "0" && s <= "9" || s >= "a" && s <= "f"
        }, "nonce should be lowercase hex")

        let u = AuthClient.buildLoginURL(baseURL: URL(string: "http://x.test")!, nonce: "n123")
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value!) })
        assert(items["desktop"] == "1")
        assert(items["state"] == "n123")
        assert(u.path == "/login")

        print("test_auth_client passed")
    }
}

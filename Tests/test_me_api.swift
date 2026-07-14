import Foundation

@main
enum TestMeAPI {
    static func main() throws {
        // Backend may return extra keys (subscription/isPro); decoding only the
        // `user` field must ignore them.
        let json = """
        {"user":{"id":"u1","email":"a@b","name":"Ann","image":null},
         "subscription":{"plan":"PRO","status":"active"},
         "isPro":true}
        """.data(using: .utf8)!
        let parsed = try MeAPI.decode(json)
        assert(parsed.user.email == "a@b")
        assert(parsed.user.name == "Ann")

        let minimal = """
        {"user":{"id":"u1","email":"a@b","name":null,"image":null}}
        """.data(using: .utf8)!
        let p2 = try MeAPI.decode(minimal)
        assert(p2.user.id == "u1")
        assert(p2.user.name == nil)

        print("test_me_api passed")
    }
}

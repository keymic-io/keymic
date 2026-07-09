import Foundation

@main
enum TestExchangeAPI {
    static func main() throws {
        let body = ExchangeAPI.encodeBody(code: "abc", state: "n1", deviceId: "HW-UUID-1", deviceName: "Test Mac")
        let dict = try JSONSerialization.jsonObject(with: body) as! [String: String]
        assert(dict["code"] == "abc")
        assert(dict["state"] == "n1")
        assert(dict["deviceId"] == "HW-UUID-1")
        assert(dict["deviceName"] == "Test Mac")

        let resp = """
        {"accessToken":"mkvc_live_xx","expiresAt":"2027-01-01T00:00:00.000Z",
         "user":{"id":"u1","email":"a@b","name":null,"image":null},
         "subscription":null}
        """.data(using: .utf8)!
        let parsed = try ExchangeAPI.decode(resp)
        assert(parsed.accessToken == "mkvc_live_xx")
        assert(parsed.user.email == "a@b")

        print("test_exchange_api passed")
    }
}

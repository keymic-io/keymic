import Foundation

struct ExchangeResponse: Codable {
    let accessToken: String
    let expiresAt: String
    let user: MeResponse.User
}

enum ExchangeAPIError: Error { case badRequest, network(Error), invalid(Int) }

enum ExchangeAPI {
    static func encodeBody(code: String, state: String, deviceId: String?, deviceName: String?) -> Data {
        var dict: [String: String] = ["code": code, "state": state]
        if let id = deviceId { dict["deviceId"] = id }
        if let d = deviceName { dict["deviceName"] = d }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    static func decode(_ data: Data) throws -> ExchangeResponse {
        try JSONDecoder().decode(ExchangeResponse.self, from: data)
    }

    static func exchange(code: String, state: String, deviceId: String?, deviceName: String?,
                         baseURL: URL = BackendConfig.baseURL,
                         session: URLSession = .shared) async throws -> ExchangeResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/desktop/exchange"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encodeBody(code: code, state: state, deviceId: deviceId, deviceName: deviceName)
        req.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 400 { throw ExchangeAPIError.badRequest }
            guard status == 200 else { throw ExchangeAPIError.invalid(status) }
            return try decode(data)
        } catch let e as ExchangeAPIError {
            throw e
        } catch {
            throw ExchangeAPIError.network(error)
        }
    }
}

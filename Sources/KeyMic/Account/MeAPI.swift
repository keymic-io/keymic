import Foundation

struct MeResponse: Codable, Equatable {
    struct User: Codable, Equatable {
        let id: String
        let email: String
        let name: String?
        let image: String?
    }
    let user: User
}

enum MeAPIError: Error { case unauthorized, network(Error), invalid(Int), decoding(Error) }

enum MeAPI {
    static func decode(_ data: Data) throws -> MeResponse {
        try JSONDecoder().decode(MeResponse.self, from: data)
    }

    static func fetch(token: String, baseURL: URL = BackendConfig.baseURL,
                      session: URLSession = .shared) async throws -> MeResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/me"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as MeAPIError {
            throw e
        } catch {
            throw MeAPIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MeAPIError.invalid(-1) }
        if http.statusCode == 401 { throw MeAPIError.unauthorized }
        guard http.statusCode == 200 else { throw MeAPIError.invalid(http.statusCode) }
        do {
            return try decode(data)
        } catch {
            throw MeAPIError.decoding(error)
        }
    }
}

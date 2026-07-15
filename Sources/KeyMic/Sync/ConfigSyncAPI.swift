import Foundation

/// One section's record as returned by the backend.
struct RemoteSection: Codable, Equatable {
    var payload: [String: JSONValue]
    var modifiedAt: Date
    var revision: Int
    var deviceId: String?
}

struct ConfigGetResponse: Codable, Equatable {
    var sections: [String: RemoteSection]
}

/// PUT response: which sections the server accepted, and the current server
/// record for any it rejected as stale (older/equal modifiedAt).
struct ConfigPutResponse: Codable, Equatable {
    var accepted: [String]
    var stale: [String: RemoteSection]
}

struct ConfigPutEntry: Codable, Equatable {
    var payload: [String: JSONValue]
    var modifiedAt: Date
}

struct ConfigPutBody: Codable, Equatable {
    var deviceId: String?
    var sections: [String: ConfigPutEntry]
}

enum ConfigSyncError: Error, Equatable {
    case unauthorized
    case network
    case invalid(Int)
    case decoding
}

/// Network seam for the sync engine. The live implementation calls
/// `ConfigSyncAPI`; tests inject a fake without touching URLSession.
protocol ConfigTransport {
    func get(token: String) async throws -> ConfigGetResponse
    func put(_ body: ConfigPutBody, token: String) async throws -> ConfigPutResponse
}

struct LiveConfigTransport: ConfigTransport {
    var baseURL: URL = BackendConfig.baseURL
    var session: URLSession = .shared
    func get(token: String) async throws -> ConfigGetResponse {
        try await ConfigSyncAPI.get(token: token, baseURL: baseURL, session: session)
    }
    func put(_ body: ConfigPutBody, token: String) async throws -> ConfigPutResponse {
        try await ConfigSyncAPI.put(body, token: token, baseURL: baseURL, session: session)
    }
}

enum ConfigSyncAPI {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func get(token: String, baseURL: URL = BackendConfig.baseURL,
                    session: URLSession = .shared) async throws -> ConfigGetResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/desktop/config"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return try await send(req, session: session)
    }

    static func put(_ body: ConfigPutBody, token: String, baseURL: URL = BackendConfig.baseURL,
                    session: URLSession = .shared) async throws -> ConfigPutResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/desktop/config"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        req.timeoutInterval = 15
        return try await send(req, session: session)
    }

    private static func send<T: Decodable>(_ req: URLRequest, session: URLSession) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ConfigSyncError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ConfigSyncError.invalid(-1) }
        if http.statusCode == 401 { throw ConfigSyncError.unauthorized }
        guard http.statusCode == 200 else { throw ConfigSyncError.invalid(http.statusCode) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ConfigSyncError.decoding
        }
    }
}

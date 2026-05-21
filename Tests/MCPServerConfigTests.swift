import Foundation

private enum MCPServerConfigTests {
    static func main() throws {
        try testStdioRoundTripWithBearerAuth()
        try testHTTPRoundTripWithOAuthAuth()
        try testSSERoundTripWithNoAuth()
        try testNoneAuthOmittedWhenEncoding()
        try testDefaultTimeoutAndEnabledOmittedWhenEncoding()
        try testUnsupportedTransportRejected()
        try testMissingURLRejected()
        try testMalformedURLRejected()
        try testNonHTTPEndpointsRejected()
        try testUnknownAuthTypeRejected()
        print("MCPServerConfigTests passed")
    }

    static func testStdioRoundTripWithBearerAuth() throws {
        let original = MCPServerConfig(
            name: "local",
            transport: .stdio(
                command: "/usr/bin/env",
                args: ["node", "server.js"],
                env: ["FOO": "bar", "BAZ": "qux"]
            ),
            auth: .bearer(accountKey: "keymic.local.token"),
            timeout: MCPTimeoutConfig(connectSeconds: 12, toolCallSeconds: 34),
            enabled: false
        )

        let data = try encodeDocument(MCPConfigDocument(servers: [original]))
        let decoded = try JSONDecoder().decode(MCPConfigDocument.self, from: data)
        expect(decoded.servers == [original], "stdio round-trip preserves config")
    }

    static func testHTTPRoundTripWithOAuthAuth() throws {
        let original = MCPServerConfig(
            name: "remote-http",
            transport: .http(url: try requireURL("https://example.com/mcp")),
            auth: .oauth(accountKey: "oauth.account"),
            timeout: .default,
            enabled: true
        )

        let data = try encodeDocument(MCPConfigDocument(servers: [original]))
        let decoded = try JSONDecoder().decode(MCPConfigDocument.self, from: data)
        expect(decoded.servers == [original], "http round-trip preserves oauth auth")
    }

    static func testSSERoundTripWithNoAuth() throws {
        let original = MCPServerConfig(
            name: "remote-sse",
            transport: .sse(url: try requireURL("https://example.com/stream"))
        )

        let data = try encodeDocument(MCPConfigDocument(servers: [original]))
        let decoded = try JSONDecoder().decode(MCPConfigDocument.self, from: data)
        expect(decoded.servers == [original], "sse round-trip preserves none auth")
    }

    static func testNoneAuthOmittedWhenEncoding() throws {
        let config = MCPServerConfig(
            name: "omit-auth",
            transport: .sse(url: try requireURL("https://example.com/events"))
        )

        let json = try jsonObject(for: config)
        expect(json["auth"] == nil, "default none auth omitted")
    }

    static func testDefaultTimeoutAndEnabledOmittedWhenEncoding() throws {
        let config = MCPServerConfig(
            name: "defaults",
            transport: .http(url: try requireURL("https://example.com/defaults"))
        )

        let json = try jsonObject(for: config)
        expect(json["timeout"] == nil, "default timeout omitted")
        expect(json["enabled"] == nil, "default enabled omitted")
    }

    static func testUnsupportedTransportRejected() throws {
        let data = Data("""
        {
          "name": "bad-transport",
          "transport": {
            "type": "websocket",
            "url": "https://example.com/socket"
          }
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(MCPServerConfig.self, from: data)
            fatalError("expected unsupportedTransport error")
        } catch let error as MCPClientError {
            guard case .unsupportedTransport(let type) = error else {
                fatalError("expected unsupportedTransport, got: \(error)")
            }
            expect(type == "websocket", "unsupported transport keeps type")
        }
    }

    static func testMissingURLRejected() throws {
        let data = Data("""
        {
          "name": "missing-url",
          "transport": {
            "type": "http"
          }
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(MCPServerConfig.self, from: data)
            fatalError("expected missing url failure")
        } catch {
            expect(error is DecodingError, "missing url throws decoding error")
        }
    }

    static func testMalformedURLRejected() throws {
        let data = Data("""
        {
          "name": "bad-url",
          "transport": {
            "type": "sse",
            "url": "not a url"
          }
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(MCPServerConfig.self, from: data)
            fatalError("expected malformed url failure")
        } catch {
            expect(error is DecodingError, "malformed url throws decoding error")
        }
    }

    static func testNonHTTPEndpointsRejected() throws {
        for rawURL in [
            "localhost:3000/mcp",
            "http:/example.com",
            "https://",
            "file:///tmp/mcp",
            "mailto:foo@example.com"
        ] {
            let data = Data("""
            {
              "name": "bad-endpoint",
              "transport": {
                "type": "http",
                "url": "\(rawURL)"
              }
            }
            """.utf8)

            do {
                _ = try JSONDecoder().decode(MCPServerConfig.self, from: data)
                fatalError("expected invalid endpoint failure for \(rawURL)")
            } catch {
                expect(error is DecodingError, "invalid endpoint throws decoding error: \(rawURL)")
            }
        }
    }

    static func testUnknownAuthTypeRejected() throws {
        let data = Data("""
        {
          "name": "bad-auth",
          "transport": {
            "type": "http",
            "url": "https://example.com/mcp"
          },
          "auth": {
            "type": "magic",
            "accountKey": "secret"
          }
        }
        """.utf8)

        do {
            _ = try JSONDecoder().decode(MCPServerConfig.self, from: data)
            fatalError("expected configInvalid error")
        } catch let error as MCPClientError {
            guard case .configInvalid(let reason) = error else {
                fatalError("expected configInvalid, got: \(error)")
            }
            expect(reason.contains("magic"), "unknown auth reason mentions type")
        }
    }

    static func encodeDocument(_ document: MCPConfigDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func jsonObject(for config: MCPServerConfig) throws -> [String: Any] {
        let data = try encodeDocument(MCPConfigDocument(servers: [config]))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = object?["servers"] as? [[String: Any]]
        guard let first = servers?.first else {
            fatalError("expected encoded server object")
        }
        return first
    }

    static func requireURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw) else {
            throw NSError(domain: "MCPServerConfigTests", code: 1)
        }
        return url
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}

@main
private enum MCPServerConfigTestRunner {
    static func main() throws {
        try MCPServerConfigTests.main()
    }
}

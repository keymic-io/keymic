import Foundation

private enum MCPConfigStoreTests {
    static func main() throws {
        try testMissingFileReturnsEmptyDocument()
        try testSaveLoadRoundTrip()
        try testMutateAppend()
        try testMalformedFileThrowsClientError()
        try testSaveCreatesParentDirectory()
        try testSaveReplacesExistingFileWithoutTmpLeftovers()
        print("MCPConfigStoreTests passed")
    }

    static func testMissingFileReturnsEmptyDocument() throws {
        let fileURL = tempRoot().appendingPathComponent("missing/mcp.json")
        let store = MCPConfigStore(fileURL: fileURL)

        let document = try store.load()
        expect(document == MCPConfigDocument(servers: []), "missing file yields empty doc")
    }

    static func testSaveLoadRoundTrip() throws {
        let root = tempRoot()
        let fileURL = root.appendingPathComponent("config/mcp.json")
        let store = MCPConfigStore(fileURL: fileURL)
        let document = MCPConfigDocument(servers: [sampleServer(name: "roundtrip")])

        try store.save(document)
        let loaded = try store.load()

        expect(loaded == document, "save/load preserves document")
    }

    static func testMutateAppend() throws {
        let root = tempRoot()
        let fileURL = root.appendingPathComponent("config/mcp.json")
        let store = MCPConfigStore(fileURL: fileURL)

        try store.mutate { document in
            document.servers.append(sampleServer(name: "first"))
        }
        try store.mutate { document in
            document.servers.append(sampleServer(name: "second"))
        }

        let loaded = try store.load()
        expect(loaded.servers.map(\.name) == ["first", "second"], "mutate appends servers")
    }

    static func testMalformedFileThrowsClientError() throws {
        let root = tempRoot()
        let fileURL = root.appendingPathComponent("config/mcp.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)
        let store = MCPConfigStore(fileURL: fileURL)

        do {
            _ = try store.load()
            fatalError("expected configInvalid error")
        } catch let error as MCPClientError {
            guard case .configInvalid(let reason) = error else {
                fatalError("expected configInvalid, got: \(error)")
            }
            expect(!reason.isEmpty, "configInvalid includes reason")
        }
    }

    static func testSaveCreatesParentDirectory() throws {
        let root = tempRoot()
        let fileURL = root
            .appendingPathComponent("nested")
            .appendingPathComponent("deep")
            .appendingPathComponent("mcp.json")
        let store = MCPConfigStore(fileURL: fileURL)

        try store.save(MCPConfigDocument(servers: [sampleServer(name: "create-parent")]))

        expect(FileManager.default.fileExists(atPath: fileURL.path), "save creates file")
        expect(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path), "save creates parent dir")
    }

    static func testSaveReplacesExistingFileWithoutTmpLeftovers() throws {
        let root = tempRoot()
        let fileURL = root.appendingPathComponent("config/mcp.json")
        let store = MCPConfigStore(fileURL: fileURL)

        try store.save(MCPConfigDocument(servers: [sampleServer(name: "before")]))
        try store.save(MCPConfigDocument(servers: [sampleServer(name: "after")]))

        let loaded = try store.load()
        expect(loaded.servers.map(\.name) == ["after"], "save replaces prior file")

        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        expect(!siblingNames.contains(where: { $0.hasSuffix(".tmp") }), "no tmp files remain after replace")
    }

    static func sampleServer(name: String) -> MCPServerConfig {
        MCPServerConfig(
            name: name,
            transport: .stdio(command: "/usr/bin/env", args: ["swift"], env: ["ENV": name]),
            auth: .bearer(accountKey: "account.\(name)"),
            timeout: MCPTimeoutConfig(connectSeconds: 5, toolCallSeconds: 10),
            enabled: true
        )
    }

    static func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-mcp-config-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
private enum MCPConfigStoreTestRunner {
    static func main() throws {
        try MCPConfigStoreTests.main()
    }
}

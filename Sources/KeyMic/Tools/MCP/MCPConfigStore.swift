import Foundation

public struct MCPConfigStore: Sendable {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.keymic/mcp.json").expandingTildeInPath)
    }

    public let fileURL: URL

    public init(fileURL: URL = Self.defaultURL) {
        self.fileURL = fileURL
    }

    public func load() throws -> MCPConfigDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MCPConfigDocument()
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MCPClientError.configInvalid(reason: "Unable to read \(fileURL.path): \(error.localizedDescription)")
        }

        do {
            return try JSONDecoder().decode(MCPConfigDocument.self, from: data)
        } catch let error as MCPClientError {
            throw error
        } catch {
            throw MCPClientError.configInvalid(reason: "Unable to decode \(fileURL.path): \(error.localizedDescription)")
        }
    }

    public func save(_ document: MCPConfigDocument) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        let tempURL = directoryURL.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: tempURL, options: [.withoutOverwriting])

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw MCPClientError.configInvalid(reason: "Unable to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    public func mutate(_ update: (inout MCPConfigDocument) throws -> Void) throws {
        var document = try load()
        try update(&document)
        try save(document)
    }
}

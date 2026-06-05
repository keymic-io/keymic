import Foundation

/// Minimal protobuf wire-format reader for parsing SentencePiece model files.
/// Only supports the subset needed for ModelProto.SentencePiece messages.
struct ProtobufReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }
    var remaining: Int { data.count - offset }

    /// Read a single byte.
    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw ProtobufError.unexpectedEnd }
        let byte = data[data.startIndex + offset]
        offset += 1
        return byte
    }

    /// Read a varint (up to 64-bit).
    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readByte()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift >= 64 { throw ProtobufError.invalidVarint }
        }
        return result
    }

    /// Read a length-delimited field (bytes).
    mutating func readBytes() throws -> Data {
        let length = Int(try readVarint())
        guard offset + length <= data.count else { throw ProtobufError.unexpectedEnd }
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + length]
        offset += length
        return Data(bytes)
    }

    /// Read a length-delimited field as UTF-8 string.
    mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw ProtobufError.invalidUTF8
        }
        return str
    }

    /// Read a 32-bit little-endian float.
    mutating func readFloat32() throws -> Float {
        guard offset + 4 <= data.count else { throw ProtobufError.unexpectedEnd }
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        offset += 4
        var value: Float = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { ptr in
            bytes.copyBytes(to: ptr)
        }
        return value
    }

    /// Skip a field based on its wire type.
    mutating func skip(wireType: UInt8) throws {
        switch wireType {
        case 0: _ = try readVarint()                    // varint
        case 1: offset += 8                              // 64-bit
        case 2: _ = try readBytes()                      // length-delimited
        case 5: offset += 4                              // 32-bit
        default: throw ProtobufError.unknownWireType(wireType)
        }
    }

    /// Read a field tag (field number + wire type).
    mutating func readTag() throws -> (fieldNumber: Int, wireType: UInt8)? {
        guard !isAtEnd else { return nil }
        let tag = try readVarint()
        let wireType = UInt8(tag & 0x07)
        let fieldNumber = Int(tag >> 3)
        return (fieldNumber, wireType)
    }
}

enum ProtobufError: Error {
    case unexpectedEnd
    case invalidVarint
    case invalidUTF8
    case unknownWireType(UInt8)
}

import Foundation

/// Minimal Codable JSON tree. Used by the sync layer so a section payload can
/// round-trip through the backend byte-for-byte, and so unknown fields written
/// by a newer app version survive an older version's collect→upload cycle.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: - Bridging to/from Foundation (UserDefaults values, JSONSerialization)

    /// Convert an arbitrary Foundation value (from `UserDefaults.object(forKey:)`
    /// or `JSONSerialization`) into a `JSONValue`. Returns nil for unsupported types.
    static func from(foundation value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let n as NSNumber:
            // Distinguish Bool from numeric NSNumber via the ObjC type encoding.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let s as String:
            return .string(s)
        case let data as Data:
            // A UserDefaults Data blob almost always holds JSON (hotkey/keymap
            // stores encode their snapshot as JSON). Decode it so it syncs as a
            // readable subtree rather than opaque base64.
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let jv = JSONValue.from(foundation: obj) {
                return .object(["__json_data__": jv])
            }
            return .string(data.base64EncodedString())
        case let arr as [Any]:
            let mapped = arr.compactMap { JSONValue.from(foundation: $0) }
            guard mapped.count == arr.count else { return nil }
            return .array(mapped)
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in dict {
                guard let jv = JSONValue.from(foundation: v) else { return nil }
                out[k] = jv
            }
            return .object(out)
        default:
            return nil
        }
    }

    /// The value to store back into UserDefaults. Data blobs previously wrapped
    /// by `from(foundation:)` are re-encoded to JSON `Data`.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundationValue }
        case .object(let o):
            if o.count == 1, let inner = o["__json_data__"] {
                let obj = inner.foundationValue
                if let data = try? JSONSerialization.data(withJSONObject: obj) {
                    return data
                }
            }
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.foundationValue }
            return out
        }
    }
}

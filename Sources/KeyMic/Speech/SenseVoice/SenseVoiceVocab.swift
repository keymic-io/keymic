import Foundation

/// SentencePiece 词表:id → token 字符串。
///
/// 主用法是在运行时解析上游 SentencePiece `.model`(protobuf)而非派生的 vocab.json:
/// `ModelProto` 的 field 1 是 `repeated SentencePiece pieces`,第 i 个 piece 的下标即 id i。
/// 每个 piece(嵌套消息)field 1 = string(原始 piece,含 `▁` 前缀、`<|...|>` 标签、`<0xHH>` 字节片)。
/// 保留原始 piece 字符串,detokenize/strip 由 `CTCDecoder` 负责,公开 API(`token(for:)`、`count`)不变。
final class SenseVoiceVocab {
    private let idToToken: [Int: String]
    var count: Int { idToToken.count }

    /// 旧的 JSON 词表 `{token: id}` 加载路径(仍保留供合成单元测试构造小词表用)。
    init(jsonPath: String) {
        guard let data = FileManager.default.contents(atPath: jsonPath),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else {
            idToToken = [:]; return
        }
        var rev = [Int: String](minimumCapacity: map.count)
        for (tok, id) in map { rev[id] = tok }
        idToToken = rev
    }

    /// 运行时解析 SentencePiece `.model`(protobuf)。第 i 个 piece 即 id i,保存原始 piece 字符串。
    init(spmModelPath: String) {
        guard let data = FileManager.default.contents(atPath: spmModelPath) else {
            idToToken = [:]; return
        }
        idToToken = Self.parseSPMModel(data)
    }

    func token(for id: Int) -> String { idToToken[id] ?? "" }

    /// 解析顶层 `ModelProto`:field 1(wire type 2)= 一个 `SentencePiece` 子消息,按出现顺序即 id。
    private static func parseSPMModel(_ data: Data) -> [Int: String] {
        var reader = ProtobufReader(data: data)
        var map: [Int: String] = [:]
        var id = 0
        do {
            while let tag = try reader.readTag() {
                if tag.fieldNumber == 1 && tag.wireType == 2 {
                    let pieceData = try reader.readBytes()
                    map[id] = parsePiece(pieceData)
                    id += 1
                } else {
                    try reader.skip(wireType: tag.wireType)
                }
            }
        } catch {
            // 解析失败:返回已解析的部分(上层会因 count 不符而失败,便于诊断)。
            return map
        }
        return map
    }

    /// 单个 `SentencePiece` 子消息:field 1(wire type 2)= piece 字符串。其余字段(score/type)跳过。
    private static func parsePiece(_ data: Data) -> String {
        var reader = ProtobufReader(data: data)
        var piece = ""
        do {
            while let tag = try reader.readTag() {
                if tag.fieldNumber == 1 && tag.wireType == 2 {
                    piece = try reader.readString()
                } else {
                    try reader.skip(wireType: tag.wireType)
                }
            }
        } catch {
            return piece
        }
        return piece
    }
}

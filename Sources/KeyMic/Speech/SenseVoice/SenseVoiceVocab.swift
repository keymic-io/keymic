import Foundation

/// SentencePiece 词表:id → token 字符串。
final class SenseVoiceVocab {
    private let idToToken: [Int: String]
    var count: Int { idToToken.count }

    init(jsonPath: String) {
        guard let data = FileManager.default.contents(atPath: jsonPath),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else {
            idToToken = [:]; return
        }
        var rev = [Int: String](minimumCapacity: map.count)
        for (tok, id) in map { rev[id] = tok }
        idToToken = rev
    }

    func token(for id: Int) -> String { idToToken[id] ?? "" }
}

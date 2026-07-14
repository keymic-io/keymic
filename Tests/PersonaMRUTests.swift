import Foundation

@main
struct PersonaMRUTestRunner {
    static func main() {
        testOrderPutsRecordedFirst()
        testOrderKeepsUnrecordedInInputOrder()
        testOrderIgnoresStaleHistoryIDs()
        testRecordMovesToFront()
        testRecordDedupes()
        testRecordCapsLength()
        print("PersonaMRUTests passed")
    }

    static func testOrderPutsRecordedFirst() {
        let a = persona("a"); let b = persona("b"); let c = persona("c")
        // history: c then a most-recent-first
        let ordered = PersonaMRU.order(personas: [a, b, c], history: ["c", "a"])
        expect(ordered.map(\.id) == ["c", "a", "b"], "recorded first in history order, then rest; got \(ordered.map(\.id))")
    }

    static func testOrderKeepsUnrecordedInInputOrder() {
        let a = persona("a"); let b = persona("b")
        let ordered = PersonaMRU.order(personas: [a, b], history: [])
        expect(ordered.map(\.id) == ["a", "b"], "empty history keeps input order; got \(ordered.map(\.id))")
    }

    static func testOrderIgnoresStaleHistoryIDs() {
        let a = persona("a")
        let ordered = PersonaMRU.order(personas: [a], history: ["deleted", "a"])
        expect(ordered.map(\.id) == ["a"], "history ids not in personas are dropped; got \(ordered.map(\.id))")
    }

    static func testRecordMovesToFront() {
        let d = UserDefaults(suiteName: "mru-test-1")!
        d.removePersistentDomain(forName: "mru-test-1")
        let mru = PersonaMRU(defaults: d)
        mru.record("a"); mru.record("b"); mru.record("a")
        expect(mru.historyIDs() == ["a", "b"], "most-recent first, deduped; got \(mru.historyIDs())")
    }

    static func testRecordDedupes() {
        let d = UserDefaults(suiteName: "mru-test-2")!
        d.removePersistentDomain(forName: "mru-test-2")
        let mru = PersonaMRU(defaults: d)
        mru.record("x"); mru.record("x")
        expect(mru.historyIDs() == ["x"], "duplicate record collapses; got \(mru.historyIDs())")
    }

    static func testRecordCapsLength() {
        let d = UserDefaults(suiteName: "mru-test-3")!
        d.removePersistentDomain(forName: "mru-test-3")
        let mru = PersonaMRU(defaults: d)
        for i in 0..<60 { mru.record("id-\(i)") }
        expect(mru.historyIDs().count == 50, "history capped at 50; got \(mru.historyIDs().count)")
        expect(mru.historyIDs().first == "id-59", "most recent stays at front; got \(String(describing: mru.historyIDs().first))")
    }

    static func persona(_ id: String) -> Persona {
        Persona(id: id, name: id, icon: "x", stylePrompt: "", temperature: 0, hotkey: nil,
                contextSources: Set<ContextSource>(), builtIn: false, createdAt: Date(), updatedAt: Date())
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

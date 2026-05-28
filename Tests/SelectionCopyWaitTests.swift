import Foundation

@main
struct SelectionCopyWaitTestRunner {
    static func main() {
        testImmediateChange()
        testEventualChange()
        testTimeout()
        testZeroBudget()
        print("SelectionCopyWaitTests passed")
    }

    /// Value already differs from initial → returns true without calling tick.
    static func testImmediateChange() {
        var tickCount = 0
        let result = SelectionCopyWait.waitForChange(
            initial: 0,
            get: { 5 },
            deadline: Date().addingTimeInterval(1.0),
            tick: { tickCount += 1 }
        )
        expect(result == true, "immediate change returns true")
        expect(tickCount == 0, "no tick when value already differs")
    }

    /// Value flips after a few ticks → returns true.
    static func testEventualChange() {
        var counter = 0
        var tickCount = 0
        let result = SelectionCopyWait.waitForChange(
            initial: 0,
            get: { counter },
            deadline: Date().addingTimeInterval(2.0),
            tick: {
                tickCount += 1
                if tickCount == 3 { counter = 1 }
            }
        )
        expect(result == true, "eventual change returns true")
        expect(tickCount >= 3, "tick was invoked at least 3 times")
    }

    /// Value never changes → loop hits deadline, returns false.
    static func testTimeout() {
        let now = Date()
        var nowCallCount = 0
        let result = SelectionCopyWait.waitForChange(
            initial: 0,
            get: { 0 },
            deadline: now.addingTimeInterval(0.1),
            now: {
                nowCallCount += 1
                return now.addingTimeInterval(Double(nowCallCount) * 0.05)
            },
            tick: {}
        )
        expect(result == false, "timeout returns false")
    }

    /// Deadline already passed → no iterations, returns false.
    static func testZeroBudget() {
        let result = SelectionCopyWait.waitForChange(
            initial: 0,
            get: { 0 },
            deadline: Date().addingTimeInterval(-1.0),
            tick: { fatalError("tick should not run") }
        )
        expect(result == false, "expired deadline returns false")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

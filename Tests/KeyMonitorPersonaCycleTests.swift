import Cocoa

@main
struct KeyMonitorPersonaCycleTestRunner {
    static func main() {
        testTabForward()
        testShiftTabBackward()
        testNonTabIsNil()
        print("KeyMonitorPersonaCycleTests passed")
    }

    static func testTabForward() {
        let dir = KeyMonitor.personaCycleDirection(keyCode: 0x30, flags: [])
        expect(dir == true, "plain Tab cycles forward; got \(String(describing: dir))")
    }

    static func testShiftTabBackward() {
        let dir = KeyMonitor.personaCycleDirection(keyCode: 0x30, flags: [.maskShift])
        expect(dir == false, "Shift+Tab cycles backward; got \(String(describing: dir))")
    }

    static func testNonTabIsNil() {
        expect(KeyMonitor.personaCycleDirection(keyCode: 0x31, flags: []) == nil, "Space is not a cycle key")
        expect(KeyMonitor.personaCycleDirection(keyCode: 0x00, flags: []) == nil, "A is not a cycle key")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

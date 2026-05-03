import Foundation

@main
struct HotkeyActionTestRunner {
    static func main() {
        // typeText round-trip
        let a1: HotkeyAction = .typeText("/clear")
        let data1 = try! JSONEncoder().encode(a1)
        let back1 = try! JSONDecoder().decode(HotkeyAction.self, from: data1)
        expect(back1 == a1, "typeText round-trip")

        // keyPress round-trip
        let a2: HotkeyAction = .keyPress(keyCode: 0x24, modifiers: 0)
        let data2 = try! JSONEncoder().encode(a2)
        let back2 = try! JSONDecoder().decode(HotkeyAction.self, from: data2)
        expect(back2 == a2, "keyPress round-trip")

        // wait round-trip
        let a3: HotkeyAction = .wait(ms: 200)
        let data3 = try! JSONEncoder().encode(a3)
        let back3 = try! JSONDecoder().decode(HotkeyAction.self, from: data3)
        expect(back3 == a3, "wait round-trip")

        // shell round-trip
        let a4: HotkeyAction = .shell("echo hi")
        let data4 = try! JSONEncoder().encode(a4)
        let back4 = try! JSONDecoder().decode(HotkeyAction.self, from: data4)
        expect(back4 == a4, "shell round-trip")

        // unknown type rejection
        let badJSON = #"{"type":"nope","x":1}"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(HotkeyAction.self, from: badJSON)
            fail("unknown type should throw")
        } catch { /* ok */ }

        // HotkeyBinding round-trip
        let b = HotkeyBinding(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            trigger: "ctrl+cmd+c",
            actions: [.typeText("/clear"), .keyPress(keyCode: 0x24, modifiers: 0)],
            enabled: true
        )
        let bData = try! JSONEncoder().encode(b)
        let bBack = try! JSONDecoder().decode(HotkeyBinding.self, from: bData)
        expect(bBack == b, "HotkeyBinding round-trip")

        print("HotkeyActionTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

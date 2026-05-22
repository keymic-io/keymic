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

        // runSkill round-trip
        let a5: HotkeyAction = .runSkill(name: "my-skill")
        let data5 = try! JSONEncoder().encode(a5)
        let back5 = try! JSONDecoder().decode(HotkeyAction.self, from: data5)
        expect(back5 == a5, "runSkill round-trip")
        let json5 = String(data: data5, encoding: .utf8) ?? ""
        expect(json5.contains("\"type\":\"runSkill\""), "runSkill JSON type: \(json5)")
        expect(json5.contains("\"name\":\"my-skill\""), "runSkill JSON name: \(json5)")

        // runAgent round-trip
        let a6: HotkeyAction = .runAgent(prompt: "Read /etc/hosts")
        let data6 = try! JSONEncoder().encode(a6)
        let back6 = try! JSONDecoder().decode(HotkeyAction.self, from: data6)
        expect(back6 == a6, "runAgent round-trip")
        let json6 = String(data: data6, encoding: .utf8) ?? ""
        expect(json6.contains("\"type\":\"runAgent\""), "runAgent JSON type: \(json6)")
        expect(json6.contains("\"prompt\":\"Read \\/etc\\/hosts\"") || json6.contains("\"prompt\":\"Read /etc/hosts\""),
               "runAgent JSON prompt: \(json6)")
        expect(HotkeyAction.runAgent(prompt: "a") == HotkeyAction.runAgent(prompt: "a"), "runAgent equal")
        expect(HotkeyAction.runAgent(prompt: "a") != HotkeyAction.runAgent(prompt: "b"), "runAgent unequal")
        expect(HotkeyAction.runAgent(prompt: "a") != HotkeyAction.runSkill(name: "a"), "runAgent vs runSkill")

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

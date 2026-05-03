import Foundation

@main
struct HotkeyActionRunnerTestRunner {
    static func main() {
        // 1. 顺序：typeText → keyPress → wait → typeText
        let log = Log()
        let runner = HotkeyActionRunner(
            typeText: { s in log.append("text:\(s)") },
            keyPress: { kc, mods in log.append("key:\(kc):\(mods)") },
            shell:    { cmd in log.append("sh:\(cmd)"); return 0 }
        )

        runner.run([
            .typeText("/clear"),
            .keyPress(keyCode: 0x24, modifiers: 0),
            .wait(ms: 50),
            .typeText("hi")
        ])

        // 等待序列完成（typeText 暗含 150ms 等待）
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))

        let entries = log.snapshot()
        expect(entries == [
            "text:/clear",
            "key:36:0",
            "text:hi"
        ], "ordered actions: \(entries)")

        // 2. shell 分支
        let log2 = Log()
        let runner2 = HotkeyActionRunner(
            typeText: { _ in },
            keyPress: { _, _ in },
            shell:    { cmd in log2.append("sh:\(cmd)"); return 0 }
        )
        runner2.run([.shell("echo hi")])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        expect(log2.snapshot() == ["sh:echo hi"], "shell invoked")

        print("HotkeyActionRunnerTests passed")
    }

    final class Log {
        private var items: [String] = []
        private let lock = NSLock()
        func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond {
            FileHandle.standardError.write(("FAIL: " + msg + "\n").data(using: .utf8)!)
            exit(1)
        }
    }
}

import Foundation

@main
struct SecureInputMonitorTestRunner {
    static func main() {
        var probedState = false
        let monitor = SecureInputMonitor(pollInterval: 60, probe: { probedState })

        var enters = 0
        var exits = 0
        monitor.onEnter = { enters += 1 }
        monitor.onExit = { exits += 1 }

        monitor.start()
        // Drain initial main-queue work from start().
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        expect(enters == 0 && exits == 0, "no callbacks before any change")

        // inactive -> active
        probedState = true
        monitor._testTick()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(enters == 1, "expected one onEnter, got \(enters)")
        expect(exits == 0, "expected zero onExit, got \(exits)")

        // active -> active (no change)
        monitor._testTick()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(enters == 1, "no second onEnter when state unchanged, got \(enters)")

        // active -> inactive
        probedState = false
        monitor._testTick()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(exits == 1, "expected one onExit, got \(exits)")

        monitor.stop()

        print("SecureInputMonitorTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

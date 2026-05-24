import Foundation

enum SelectionCopyWait {
    /// Spins until `get()` returns a value different from `initial`, or `now() >= deadline`.
    /// `tick()` runs between checks (callers use it to spin the RunLoop, sleep, etc.).
    /// Returns true if a change was observed, false on timeout.
    static func waitForChange(
        initial: Int,
        get: () -> Int,
        deadline: Date,
        now: () -> Date = { Date() },
        tick: () -> Void
    ) -> Bool {
        while now() < deadline {
            if get() != initial { return true }
            tick()
        }
        return get() != initial
    }
}

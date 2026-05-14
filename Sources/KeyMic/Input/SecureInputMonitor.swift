import Carbon
import Foundation
import os.log

/// Polls `IsSecureEventInputEnabled()` and fires callbacks on the main queue
/// when Secure Input becomes active or inactive. Required because macOS does
/// not deliver a notification for Secure Input transitions, and event taps can
/// silently miss key-up events while Secure Input is engaged.
///
/// Why polling instead of notification: Karabiner-Elements uses the same 200ms
/// polling cadence for the same reason — there is no public API.
final class SecureInputMonitor {
    /// Called on the main queue when Secure Input transitions inactive → active.
    var onEnter: (() -> Void)?
    /// Called on the main queue when Secure Input transitions active → inactive.
    var onExit: (() -> Void)?

    private let pollInterval: TimeInterval
    private let probe: () -> Bool
    private let log = Logger(subsystem: "io.keymic.app", category: "SecureInputMonitor")
    private var timer: DispatchSourceTimer?
    private var lastState: Bool = false

    /// - Parameters:
    ///   - pollInterval: how often to sample (default 0.2s — matches Karabiner-Elements).
    ///   - probe: closure that returns the current Secure Input state. Injectable for tests.
    init(pollInterval: TimeInterval = 0.2,
         probe: @escaping () -> Bool = { IsSecureEventInputEnabled() }) {
        self.pollInterval = pollInterval
        self.probe = probe
    }

    func start() {
        guard timer == nil else { return }
        lastState = probe()
        log.info("SecureInputMonitor start initialState=\(self.lastState, privacy: .public)")
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Test seam: drive the monitor manually instead of via the timer.
    func _testTick() { tick() }

    private func tick() {
        let now = probe()
        if now == lastState { return }
        lastState = now
        log.info("SecureInput state changed -> \(now ? "active" : "inactive", privacy: .public)")
        if now {
            onEnter?()
        } else {
            onExit?()
        }
    }
}

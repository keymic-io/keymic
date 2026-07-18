import Foundation

/// Spy sink that records every capture as `kind|file` and counts shutdowns, so the test
/// can assert gating behaviour plus the exact `ErrorKind` and file id passed through.
final class SpyCrashSink: CrashReportingSink {
    private(set) var calls: [String] = []
    private(set) var shutdownCount = 0
    var count: Int { calls.count }

    func capture(_ kind: ErrorKind, file: String) {
        calls.append("\(kind.rawValue)|\(file)")
    }
    func shutdown() { shutdownCount += 1 }
}

@main
struct CrashReportingGatingTests {
    static func main() {
        // Scratch defaults so setEnabled doesn't touch the real domain.
        let suite = "io.keymic.app.crash.test"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // 1. Disabled -> zero sink calls.
        let spy1 = SpyCrashSink()
        let disabled = CrashReportingGate(sink: spy1, enabled: false, defaults: defaults)
        disabled.capture(.llm, file: "LLMClient.swift")
        disabled.capture(.modelDownload, file: "AssetStore.swift")
        assert(spy1.count == 0, "disabled gate must not capture; got \(spy1.count)")

        // 2. Enabled -> sink receives the exact ErrorKind + file, no content.
        let spy2 = SpyCrashSink()
        let enabled = CrashReportingGate(sink: spy2, enabled: true, defaults: defaults)
        enabled.sinkProvider = { spy2 }   // rebuild path after a toggle-off
        enabled.capture(.llm, file: "LLMClient.swift")
        enabled.capture(.engineStart, file: "SenseVoiceEngine.swift")
        assert(spy2.count == 2, "enabled gate should capture 2; got \(spy2.count)")
        assert(spy2.calls[0] == "llm|LLMClient.swift", "unexpected capture[0]: \(spy2.calls[0])")
        assert(spy2.calls[1] == "engineStart|SenseVoiceEngine.swift",
               "unexpected capture[1]: \(spy2.calls[1])")

        // 3. Toggling off -> SDK shut down, no further captures.
        enabled.setEnabled(false)
        assert(spy2.shutdownCount == 1, "toggle-off must shut down the sink; got \(spy2.shutdownCount)")
        enabled.capture(.configSync, file: "SyncEngine.swift")
        assert(spy2.count == 2, "no capture after toggle-off; got \(spy2.count)")
        assert(defaults.bool(forKey: CrashReportingGate.enabledKey) == false,
               "toggle-off must persist the shared flag as false")

        // 4. ...and back on rebuilds via the provider and resumes capturing.
        enabled.setEnabled(true)
        enabled.capture(.modelDownload, file: "AssetStore.swift")
        assert(spy2.count == 3, "capture resumes after toggle-on; got \(spy2.count)")
        assert(spy2.calls[2] == "modelDownload|AssetStore.swift",
               "unexpected capture[2]: \(spy2.calls[2])")

        // 5. Shared consent key is exactly the TelemetryDeck key (one toggle, both tools).
        assert(CrashReportingGate.enabledKey == "telemetryEnabled",
               "crash gate must reuse the shared telemetryEnabled key; got \(CrashReportingGate.enabledKey)")

        // 6. Default-on: fresh domain with no stored value reads as enabled.
        defaults.removePersistentDomain(forName: suite)
        let fresh = CrashReportingGate(defaults: defaults)
        assert(fresh.isEnabled == true, "consent must default to true when unset")

        defaults.removePersistentDomain(forName: suite)
        print("CrashReportingGatingTests passed")
    }

    static func assert(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

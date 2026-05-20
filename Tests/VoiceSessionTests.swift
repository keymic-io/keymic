import Foundation

@main
struct VoiceSessionTestRunner {
    static func main() {
        testCancelInvokesHookExactlyOnce()
        testDeinitInvokesHookIfNotAlreadyCanceled()
        print("VoiceSessionTests passed")
    }

    static func testCancelInvokesHookExactlyOnce() {
        var calls = 0
        let session = VoiceSession { calls += 1 }
        session.cancel()
        session.cancel()
        session.cancel()
        precondition(calls == 1, "cancel() must be idempotent (was \(calls))")
    }

    static func testDeinitInvokesHookIfNotAlreadyCanceled() {
        var calls = 0
        do {
            _ = VoiceSession { calls += 1 }
        }
        precondition(calls == 1, "deinit must close the session (was \(calls))")
    }
}

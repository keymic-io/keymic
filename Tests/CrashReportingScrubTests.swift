import Foundation

/// Fake event standing in for Sentry's `Event`, so the pure `CrashScrub` allowlist can be
/// tested without linking Sentry. Models the three fields the scrub touches.
final class FakeEvent: ScrubbableEvent {
    var scrubMessage: String?
    private var breadcrumbs: [String]
    private var extra: [String: String]

    init(message: String?, breadcrumbs: [String], extra: [String: String]) {
        self.scrubMessage = message
        self.breadcrumbs = breadcrumbs
        self.extra = extra
    }

    var scrubHasBreadcrumbs: Bool { !breadcrumbs.isEmpty }
    var scrubHasExtra: Bool { !extra.isEmpty }
    func scrubDropBreadcrumbs() { breadcrumbs = [] }
    func scrubDropExtra() { extra = [:] }
}

@main
struct CrashReportingScrubTests {
    static func main() {
        // 1. A content-looking message (transcript-like) is blanked; breadcrumbs + extra dropped.
        let leaky = FakeEvent(
            message: "user said: my password is hunter2 and my card is 4111 1111 1111 1111",
            breadcrumbs: ["clipboard: secret-token-abc", "keydown: cmd+v"],
            extra: ["transcript": "the quick brown fox", "clipboardTop": "s3cr3t"]
        )
        let scrubbedLeaky = CrashScrub.scrub(leaky)
        assert(scrubbedLeaky.scrubMessage == nil, "content message must be blanked; got \(String(describing: scrubbedLeaky.scrubMessage))")
        assert(!scrubbedLeaky.scrubHasBreadcrumbs, "breadcrumbs must be dropped")
        assert(!scrubbedLeaky.scrubHasExtra, "extra must be dropped")

        // 2. An allowlisted synthetic message survives; breadcrumbs + extra still dropped.
        let safeMessage = CrashScrub.syntheticMessage(for: .llm)
        let ours = FakeEvent(
            message: safeMessage,
            breadcrumbs: ["network: 500"],
            extra: ["foreign": "x"]
        )
        let scrubbedOurs = CrashScrub.scrub(ours)
        assert(scrubbedOurs.scrubMessage == safeMessage, "allowlisted message must survive; got \(String(describing: scrubbedOurs.scrubMessage))")
        assert(!scrubbedOurs.scrubHasBreadcrumbs, "breadcrumbs must be dropped even for our own events")
        assert(!scrubbedOurs.scrubHasExtra, "extra must be dropped even for our own events")

        // 3. A nil message is left as-is (crash events derive their own exception fields).
        let crash = FakeEvent(message: nil, breadcrumbs: [], extra: [:])
        let scrubbedCrash = CrashScrub.scrub(crash)
        assert(scrubbedCrash.scrubMessage == nil, "nil message must stay nil")

        // 4. Every ErrorKind's synthetic message is in the allowlist and content-free.
        for kind in ErrorKind.allCases {
            let msg = CrashScrub.syntheticMessage(for: kind)
            assert(CrashScrub.allowedMessages.contains(msg), "\(kind) synthetic message not allowlisted: \(msg)")
            assert(CrashScrub.isMessageAllowed(msg), "\(kind) synthetic message rejected by allowlist")
            assert(msg == "KeyMic error: \(kind.rawValue)", "unexpected synthetic message for \(kind): \(msg)")
        }

        // 5. isMessageAllowed contract: nil safe, allowlisted safe, arbitrary text rejected.
        assert(CrashScrub.isMessageAllowed(nil), "nil message must be allowed")
        assert(!CrashScrub.isMessageAllowed("arbitrary user text"), "arbitrary text must be rejected")

        print("CrashReportingScrubTests passed")
    }

    static func assert(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

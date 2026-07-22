import Foundation

@main
struct VoiceScratchpadDecisionTestRunner {
    static func main() {
        expect(VoiceScratchpadDecision.shouldOpen(for: .nonEditable),
               "no editable target should open the scratchpad")
        expect(!VoiceScratchpadDecision.shouldOpen(for: .editable),
               "an editable field should paste, not open the scratchpad")
        expect(!VoiceScratchpadDecision.shouldOpen(for: .unknown),
               "unknown (AX-unsupported apps like VSCode/Slack) must paste, not divert")

        print("VoiceScratchpadDecisionTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

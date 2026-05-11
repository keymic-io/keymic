import CoreGraphics
import Foundation

@main
struct InputStateTestRunner {
    static func main() {
        // Empty state: resetTransient is a no-op and returns the prior (empty) state.
        var state = InputState()
        let priorEmpty = state.resetTransient()
        expect(priorEmpty.triggerActive == false, "empty prior triggerActive should be false")
        expect(priorEmpty.heldModifiers.isEmpty, "empty prior heldModifiers should be empty")
        expect(priorEmpty.remappedKeysDown.isEmpty, "empty prior remappedKeysDown should be empty")
        expect(state.triggerActive == false, "after empty reset: triggerActive false")
        expect(state.heldModifiers.isEmpty, "after empty reset: heldModifiers empty")

        // Dirty state: mimics a missed key-up scenario where Fn + Right Cmd are stuck
        // and a remapped key is still down.
        state.triggerActive = true
        state.heldModifiers = [0x3F, 0x36]
        state.remappedKeysDown = [0x36]

        let prior = state.resetTransient()
        expect(prior.triggerActive == true, "prior should preserve triggerActive=true")
        expect(prior.heldModifiers == [0x3F, 0x36], "prior should preserve heldModifiers")
        expect(prior.remappedKeysDown == [0x36], "prior should preserve remappedKeysDown")
        expect(state.triggerActive == false, "after reset: triggerActive=false")
        expect(state.heldModifiers.isEmpty, "after reset: heldModifiers empty")
        expect(state.remappedKeysDown.isEmpty, "after reset: remappedKeysDown empty")

        // Idempotency: a second reset on an already-empty state must not crash and stays empty.
        let priorIdempotent = state.resetTransient()
        expect(priorIdempotent.triggerActive == false, "idempotent reset: prior=false")
        expect(state.heldModifiers.isEmpty, "idempotent reset: still empty")

        print("InputStateTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

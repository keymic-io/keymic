import Foundation

@main
struct WindowOCRTestRunner {
    static func main() {
        testPermissionProbeReturnsBool()
        testWindowOCRErrorEquatableCases()
        testResolvedRecognitionLanguages_prefixMatch()
        testResolvedRecognitionLanguages_emptyPreferred()
        testResolvedRecognitionLanguages_noMatch()
        testResolvedRecognitionLanguages_preservesPreferredOrder()
        testPickFocusedWindow_picksLargestOnScreenLayerZero()
        testPickFocusedWindow_filtersOffScreen()
        testPickFocusedWindow_filtersNonZeroLayer()
        testPickFocusedWindow_filtersForeignPID()
        testPickFocusedWindow_emptyReturnsNil()
        testPickFocusedWindow_noMatchingPIDReturnsNil()
        print("WindowOCRTests passed")
    }

    static func testPermissionProbeReturnsBool() {
        let value: Bool = WindowOCRProvider.hasScreenRecordingPermission()
        _ = value
    }

    static func testWindowOCRErrorEquatableCases() {
        let cases: [WindowOCRError] = [
            .noFocusedWindow,
            .screenRecordingDenied,
        ]
        for e in cases {
            switch e {
            case .noFocusedWindow, .screenRecordingDenied, .captureFailed, .visionFailed:
                continue
            }
        }
    }

    static func testResolvedRecognitionLanguages_prefixMatch() {
        let got = WindowOCRProvider.resolvedRecognitionLanguages(
            preferred: ["zh-Hans-CN", "en-US"],
            supported: ["en-US", "zh-Hans", "fr-FR"]
        )
        expect(got == ["zh-Hans", "en-US"],
               "BCP-47 prefix match should map zh-Hans-CN → zh-Hans and preserve preferred order, got: \(got)")
    }

    static func testResolvedRecognitionLanguages_emptyPreferred() {
        let got = WindowOCRProvider.resolvedRecognitionLanguages(
            preferred: [],
            supported: ["en-US"]
        )
        expect(got == [], "empty preferred should produce empty list (let Vision default), got: \(got)")
    }

    static func testResolvedRecognitionLanguages_noMatch() {
        let got = WindowOCRProvider.resolvedRecognitionLanguages(
            preferred: ["xx-YY"],
            supported: ["en-US"]
        )
        expect(got == [], "unsupported preferred should produce empty list, got: \(got)")
    }

    static func testResolvedRecognitionLanguages_preservesPreferredOrder() {
        let got = WindowOCRProvider.resolvedRecognitionLanguages(
            preferred: ["fr-FR", "en-US", "zh-Hans-CN"],
            supported: ["en-US", "zh-Hans", "fr-FR"]
        )
        expect(got == ["fr-FR", "en-US", "zh-Hans"],
               "preferred-order preservation broken, got: \(got)")
    }

    struct FakeWindow: WindowCandidate, Equatable {
        let owningPID: pid_t?
        let isOnScreen: Bool
        let windowLayer: Int
        let frameArea: CGFloat
        var debugID: String
    }

    static func testPickFocusedWindow_picksLargestOnScreenLayerZero() {
        let windows: [FakeWindow] = [
            FakeWindow(owningPID: 42, isOnScreen: true, windowLayer: 0, frameArea: 100_000, debugID: "small"),
            FakeWindow(owningPID: 42, isOnScreen: true, windowLayer: 0, frameArea: 500_000, debugID: "large"),
            FakeWindow(owningPID: 42, isOnScreen: true, windowLayer: 0, frameArea: 250_000, debugID: "medium"),
        ]
        let picked = WindowOCRProvider.pickFocusedWindow(in: windows, frontPID: 42)
        expect(picked?.debugID == "large", "should pick largest-area window, got: \(String(describing: picked?.debugID))")
    }

    static func testPickFocusedWindow_filtersOffScreen() {
        let windows: [FakeWindow] = [
            FakeWindow(owningPID: 42, isOnScreen: false, windowLayer: 0, frameArea: 1_000_000, debugID: "offscreen-large"),
            FakeWindow(owningPID: 42, isOnScreen: true,  windowLayer: 0, frameArea: 100_000,   debugID: "onscreen-small"),
        ]
        let picked = WindowOCRProvider.pickFocusedWindow(in: windows, frontPID: 42)
        expect(picked?.debugID == "onscreen-small", "off-screen window should be filtered, got: \(String(describing: picked?.debugID))")
    }

    static func testPickFocusedWindow_filtersNonZeroLayer() {
        let windows: [FakeWindow] = [
            FakeWindow(owningPID: 42, isOnScreen: true, windowLayer: 3,  frameArea: 1_000_000, debugID: "floating"),
            FakeWindow(owningPID: 42, isOnScreen: true, windowLayer: 0,  frameArea: 100_000,   debugID: "content"),
        ]
        let picked = WindowOCRProvider.pickFocusedWindow(in: windows, frontPID: 42)
        expect(picked?.debugID == "content", "non-zero windowLayer should be filtered, got: \(String(describing: picked?.debugID))")
    }

    static func testPickFocusedWindow_filtersForeignPID() {
        let windows: [FakeWindow] = [
            FakeWindow(owningPID: 99, isOnScreen: true, windowLayer: 0, frameArea: 1_000_000, debugID: "other-app"),
            FakeWindow(owningPID: 42, isOnScreen: true, windowLayer: 0, frameArea: 100_000,   debugID: "front-app"),
        ]
        let picked = WindowOCRProvider.pickFocusedWindow(in: windows, frontPID: 42)
        expect(picked?.debugID == "front-app", "non-front PID should be filtered, got: \(String(describing: picked?.debugID))")
    }

    static func testPickFocusedWindow_emptyReturnsNil() {
        let picked = WindowOCRProvider.pickFocusedWindow(in: [FakeWindow](), frontPID: 42)
        expect(picked == nil, "empty list should return nil")
    }

    static func testPickFocusedWindow_noMatchingPIDReturnsNil() {
        let windows: [FakeWindow] = [
            FakeWindow(owningPID: 99, isOnScreen: true, windowLayer: 0, frameArea: 100_000, debugID: "other"),
        ]
        let picked = WindowOCRProvider.pickFocusedWindow(in: windows, frontPID: 42)
        expect(picked == nil, "all-foreign PIDs should return nil, got: \(String(describing: picked?.debugID))")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        if !condition() { fail(message()) }
    }
}

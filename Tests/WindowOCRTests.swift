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

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        if !condition() { fail(message()) }
    }
}

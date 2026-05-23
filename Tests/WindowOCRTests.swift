import Foundation

@main
struct WindowOCRTestRunner {
    static func main() {
        testPermissionProbeReturnsBool()
        testWindowOCRErrorEquatableCases()
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

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        if !condition() { fail(message()) }
    }
}

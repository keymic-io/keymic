import Foundation

@main
struct WindowOCRTestRunner {
    static func main() async {
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
        await testBuilder_gathersOnlyDeclaredSources()
        await testBuilder_emptyContextSourcesGathersNothing()
        await testBuilder_postsStatusUpdateForOCR()
        await testBuilder_swallowsOCRThrow()
        await testBuilder_canonicalOrderViaPersonaContext()
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

    static func testBuilder_gathersOnlyDeclaredSources() async {
        var selectionCalls = 0
        var clipboardTopCalls = 0
        var clipboardHistoryCalls = 0
        var ocrCalls = 0
        let providers = await PersonaContextBuilder.Providers(
            selection: { selectionCalls += 1; return "SEL" },
            clipboardTop: { clipboardTopCalls += 1; return "CLIP" },
            clipboardHistory: { _ in clipboardHistoryCalls += 1; return ["h1", "h2"] },
            windowOCR: { ocrCalls += 1; return "OCR" }
        )
        let sources: Set<ContextSource> = [.selection, .windowOCR]
        let ctx = await PersonaContextBuilder.testBuild(
            sources: sources, providers: providers, onStatusUpdate: { _ in }
        )
        expect(selectionCalls == 1, "selection should be called once, got \(selectionCalls)")
        expect(clipboardTopCalls == 0, "clipboardTop must NOT be called when not declared, got \(clipboardTopCalls)")
        expect(clipboardHistoryCalls == 0, "clipboardHistory must NOT be called when not declared")
        expect(ocrCalls == 1, "windowOCR should be called once, got \(ocrCalls)")
        expect(ctx.selection == "SEL", "selection field wrong: \(String(describing: ctx.selection))")
        expect(ctx.clipboardTop == nil, "clipboardTop should be nil")
        expect(ctx.clipboardHistory == nil, "clipboardHistory should be nil")
        expect(ctx.windowOCR == "OCR", "windowOCR field wrong: \(String(describing: ctx.windowOCR))")
    }

    static func testBuilder_emptyContextSourcesGathersNothing() async {
        var anyCalled = false
        let providers = await PersonaContextBuilder.Providers(
            selection: { anyCalled = true; return "X" },
            clipboardTop: { anyCalled = true; return "X" },
            clipboardHistory: { _ in anyCalled = true; return ["X"] },
            windowOCR: { anyCalled = true; return "X" }
        )
        let ctx = await PersonaContextBuilder.testBuild(
            sources: [], providers: providers, onStatusUpdate: { _ in }
        )
        expect(!anyCalled, "no provider should be called for empty sources")
        expect(ctx == PersonaContext.empty, "context should equal .empty for empty sources")
    }

    static func testBuilder_postsStatusUpdateForOCR() async {
        var statuses: [String] = []
        let providers = await PersonaContextBuilder.Providers(
            selection: { nil },
            clipboardTop: { nil },
            clipboardHistory: { _ in nil },
            windowOCR: { "OCR" }
        )
        _ = await PersonaContextBuilder.testBuild(
            sources: [.windowOCR],
            providers: providers,
            onStatusUpdate: { statuses.append($0) }
        )
        expect(statuses.contains(where: { $0.localizedCaseInsensitiveContains("reading") }),
               "expected a 'Reading screen…' status update, got: \(statuses)")
    }

    static func testBuilder_swallowsOCRThrow() async {
        let providers = await PersonaContextBuilder.Providers(
            selection: { "SEL" },
            clipboardTop: { nil },
            clipboardHistory: { _ in nil },
            windowOCR: { throw WindowOCRError.screenRecordingDenied }
        )
        let ctx = await PersonaContextBuilder.testBuild(
            sources: [.selection, .windowOCR],
            providers: providers,
            onStatusUpdate: { _ in }
        )
        expect(ctx.selection == "SEL", "selection should still populate when OCR throws, got: \(String(describing: ctx.selection))")
        expect(ctx.windowOCR == nil, "windowOCR must be nil after thrown error, got: \(String(describing: ctx.windowOCR))")
    }

    static func testBuilder_canonicalOrderViaPersonaContext() async {
        let providers = await PersonaContextBuilder.Providers(
            selection: { "S" },
            clipboardTop: { "C" },
            clipboardHistory: { _ in ["h1"] },
            windowOCR: { "W" }
        )
        let ctx = await PersonaContextBuilder.testBuild(
            sources: [.selection, .clipboardTop, .clipboardHistory, .windowOCR],
            providers: providers,
            onStatusUpdate: { _ in }
        )
        let prompt = ctx.buildPrompt(transcript: "T",
                                     sources: [.selection, .clipboardTop, .clipboardHistory, .windowOCR])
        let expected = "[Selected text]\nS\n\n[Recent clipboard]\nC\n\n[Clipboard history]\n1. h1\n\n[Window text]\nW\n\n[User said]\nT"
        expect(prompt == expected, "canonical order mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        if !condition() { fail(message()) }
    }
}

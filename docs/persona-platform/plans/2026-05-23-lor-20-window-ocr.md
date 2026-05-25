# LOR-20 Window OCR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `WindowOCRProvider.recognize()` — captures the focused window via ScreenCaptureKit, runs Vision OCR, returns plain text — and centralise persona context gathering behind a new `PersonaContextBuilder.build(...)` so personas declaring `.windowOCR` (already present from LOR-18) actually populate `PersonaContext.windowOCR` before the LLM call. Overlay shows "Reading screen…" while OCR runs; missing Screen Recording permission degrades gracefully with a one-time toast.

**Architecture:** Additive-first. Land two new files (`Sources/KeyMic/Context/WindowOCRProvider.swift`, `Sources/KeyMic/LLM/PersonaContextBuilder.swift`) plus a new test runner (`Tests/WindowOCRTests.swift`). Each task ends in a green commit. The inline context-gathering in `AppDelegate.finishTranscription` is replaced by a single `await PersonaContextBuilder.build(for: persona, ...)` call only once the builder is fully wired and tested. Untestable mechanisms (SCShareableContent, SCScreenshotManager, VNRecognizeTextRequest) ship behind pure-logic helpers (`resolvedRecognitionLanguages`, `pickFocusedWindow`) that ARE unit tested; the capture+Vision pipeline gets a manual smoke matrix.

**Tech Stack:** Swift 5.9, SwiftPM single target (KeyMic), Foundation-only standalone `swiftc` test runners under `Tests/`. No XCTest. macOS 14. Frameworks added at link time only via the Makefile target's `-framework` flags as needed; the main app already links AppKit / ScreenCaptureKit / Vision.

**Source spec:** `docs/persona-platform/2026-05-23-lor-20-window-ocr.md`

**Depends on (already shipped):**
- LOR-18 (`ContextSource.windowOCR`, `PersonaContext.windowOCR: String?`, `Persona.contextSources: Set<ContextSource>`).
- `Sources/KeyMic/Screenshot/ScreenCapturer.swift` — pattern for SCShareableContent / SCScreenshotManager / TCC translation.
- `Sources/KeyMic/OverlayPanel.swift` — `updateText(_:)`, `showTransientToast(_:durationSeconds:)`, `showRefining()`.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/KeyMic/Context/WindowOCRProvider.swift` | Create | `WindowOCRError` enum + `actor WindowOCRProvider` with `recognize()`, `hasScreenRecordingPermission()`, plus pure-logic helpers `resolvedRecognitionLanguages(preferred:supported:)` and `pickFocusedWindow(in:frontPID:)`. |
| `Sources/KeyMic/LLM/PersonaContextBuilder.swift` | Create | `@MainActor enum PersonaContextBuilder` with `build(for:clipboardStore:onStatusUpdate:)`. Conditionally gathers each source the persona declares. Reads selection + clipboard top inline; awaits OCR last. |
| `Sources/KeyMic/AppDelegate.swift` | Modify | `finishTranscription(text:)` replaces `PersonaContext.snapshotCurrent()` with `await PersonaContextBuilder.build(for:onStatusUpdate:)`. New helper `maybeShowOCRPermissionToast()`. |
| `Tests/WindowOCRTests.swift` | Create | Pure-logic tests: `resolvedRecognitionLanguages` cases, `pickFocusedWindow` heuristic on injected fakes, `PersonaContextBuilder.build` conditional-gather using stub providers. `@main struct WindowOCRTestRunner`. |
| `Makefile` | Modify | Add `test-window-ocr` rule. Append `test-window-ocr` to the `test-all:` dependency line. |
| `Sources/KeyMic/LLM/ClipboardStore.swift` | (read-only reference) | Confirm `recentTexts(limit:)` signature used by builder. |

---

## Task 1: `WindowOCRError` + permission probe + Makefile stub + failing-test scaffold

**Files:**
- Create: `Sources/KeyMic/Context/WindowOCRProvider.swift` (stub only — error enum + permission probe)
- Create: `Tests/WindowOCRTests.swift` (runner skeleton + permission-probe test)
- Modify: `Makefile` (add `test-window-ocr` rule, append to `test-all`)

- [ ] **Step 1: Write the failing test runner skeleton.**

`Tests/WindowOCRTests.swift`:

```swift
import Foundation

@main
struct WindowOCRTestRunner {
    static func main() {
        testPermissionProbeReturnsBool()
        testWindowOCRErrorEquatableCases()
        print("WindowOCRTests passed")
    }

    static func testPermissionProbeReturnsBool() {
        // Pure shape test: the probe must be callable and return Bool.
        // Cannot assert the value (depends on the test runner's TCC state).
        let value: Bool = WindowOCRProvider.hasScreenRecordingPermission()
        _ = value
    }

    static func testWindowOCRErrorEquatableCases() {
        let cases: [WindowOCRError] = [
            .noFocusedWindow,
            .screenRecordingDenied,
        ]
        for e in cases {
            // Compile-time check that the cases exist + are reachable.
            switch e {
            case .noFocusedWindow, .screenRecordingDenied, .captureFailed, .visionFailed:
                continue
            }
        }
    }
}

// Local helpers shared across test methods.
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() { fail(message()) }
}
```

- [ ] **Step 2: Run test — expect compile failure (no `WindowOCRProvider` symbol yet).**

Run: `mkdir -p .build && swiftc Tests/WindowOCRTests.swift -o .build/window-ocr-tests 2>&1 | head -5`

Expected: compile fails with "cannot find 'WindowOCRProvider' in scope" / "cannot find 'WindowOCRError' in scope".

- [ ] **Step 3: Write the minimal implementation.**

`Sources/KeyMic/Context/WindowOCRProvider.swift`:

```swift
import AppKit
import CoreGraphics

/// Errors emitted by `WindowOCRProvider.recognize()`.
/// `.noFocusedWindow` is **not** thrown by `recognize()` itself (which returns nil for no-window);
/// it exists for explicit callers that want to distinguish "no window" from "permission denied".
enum WindowOCRError: Error {
    /// NSWorkspace returned nil / window not in SCShareableContent.
    case noFocusedWindow
    /// TCC denial — surfaces as SCShareableContent failure.
    case screenRecordingDenied
    /// SCScreenshotManager threw.
    case captureFailed(Error)
    /// VNImageRequestHandler / VNRecognizeTextRequest threw.
    case visionFailed(Error)
}

/// Captures the currently focused window and runs Vision OCR on the pixels.
/// Actor-isolated so concurrent voice triggers serialize (one OCR at a time).
actor WindowOCRProvider {
    static let shared = WindowOCRProvider()

    /// Returns true if Screen Recording TCC is currently granted.
    /// Static so the synchronous permission gate in `PersonaContextBuilder` doesn't need actor hopping.
    nonisolated static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}
```

- [ ] **Step 4: Add Makefile target.**

Append after `test-selected-text-editor:` (around line 535 in `Makefile`):

```makefile
test-window-ocr:
	mkdir -p .build
	swiftc Sources/KeyMic/Context/WindowOCRProvider.swift \
	       Tests/WindowOCRTests.swift \
	       -o .build/window-ocr-tests
	.build/window-ocr-tests
```

Modify the `test-all:` line (currently line 537) — append `test-window-ocr` to the end of the dependency chain, immediately before the trailing target list end:

```
test-all: test test-clipboard-store test-clipboard-monitor test-cleanup-policy test-hotkey-config test-hotkey-action test-hotkey-bindings-store test-hotkey-settings-store test-toml-parser test-kind-classifier test-hotkey-action-runner test-keymonitor-clipboard-panel test-single-instance test-speech-engine test-keychain-vault test-secret-scanner test-vault-store test-annotation-model test-pixelator test-renderer test-selection-handles test-toolbar-positioner test-overlay-state test-persona test-persona-store test-persona-context test-persona-injection-strategy test-output-router test-hotkey-registry test-shell-logger test-shell-snapshot test-shell-runner test-clipboard-store-binary test-clipboard-monitor-types test-thumbnail-cache test-input-state test-secure-input-monitor test-voice-session test-voice-state-machine test-pasteboard-snapshot test-selection-copy-wait test-selected-text-editor test-context-source test-clipboard-transform test-window-ocr
```

- [ ] **Step 5: Run test — expect green.**

Run: `make test-window-ocr`

Expected stdout: `WindowOCRTests passed`.

- [ ] **Step 6: Run full build to confirm no other breakage.**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!` and no `error:` lines.

- [ ] **Step 7: Commit.**

```bash
git add Sources/KeyMic/Context/WindowOCRProvider.swift \
        Tests/WindowOCRTests.swift \
        Makefile
git commit -m "feat(window-ocr): add WindowOCRError + permission probe scaffold (LOR-20)"
```

---

## Task 2: Pure-logic `resolvedRecognitionLanguages(preferred:supported:)`

**Files:**
- Modify: `Sources/KeyMic/Context/WindowOCRProvider.swift` (add static helper)
- Modify: `Tests/WindowOCRTests.swift` (add 3 test cases per spec §8)

This is the language-list filter from spec §5.3. Pure on `[String]` inputs so it's unit-testable without Vision.

- [ ] **Step 1: Write failing tests.**

In `Tests/WindowOCRTests.swift`, add to `main()` (after `testWindowOCRErrorEquatableCases()`, before the `print(...)`):

```swift
        testResolvedRecognitionLanguages_prefixMatch()
        testResolvedRecognitionLanguages_emptyPreferred()
        testResolvedRecognitionLanguages_noMatch()
        testResolvedRecognitionLanguages_preservesPreferredOrder()
```

Add at the bottom of the struct (before the closing brace):

```swift
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
```

- [ ] **Step 2: Run test — expect compile failure.**

Run: `make test-window-ocr 2>&1 | head -10`

Expected: `error: type 'WindowOCRProvider' has no member 'resolvedRecognitionLanguages'`.

- [ ] **Step 3: Add the helper to `WindowOCRProvider.swift`.**

Append inside the `WindowOCRProvider` actor (after `hasScreenRecordingPermission()`):

```swift
    /// Filters the user's preferred BCP-47 language list down to Vision's supported set.
    /// Match rule: an entry like `zh-Hans-CN` matches a supported `zh-Hans` (longest-prefix match
    /// over `-`-separated subtags). Preferred order is preserved; unsupported entries dropped.
    /// Returns `[]` when nothing matches — caller should pass `[]` straight to
    /// `VNRecognizeTextRequest.recognitionLanguages` so Vision falls back to its default.
    nonisolated static func resolvedRecognitionLanguages(
        preferred: [String],
        supported: [String]
    ) -> [String] {
        var result: [String] = []
        for pref in preferred {
            // Try exact match first.
            if supported.contains(pref) {
                if !result.contains(pref) { result.append(pref) }
                continue
            }
            // Try progressively shorter prefixes (drop trailing `-X` subtags).
            var subtags = pref.split(separator: "-").map(String.init)
            while subtags.count > 1 {
                subtags.removeLast()
                let candidate = subtags.joined(separator: "-")
                if supported.contains(candidate) {
                    if !result.contains(candidate) { result.append(candidate) }
                    break
                }
            }
        }
        return result
    }
```

- [ ] **Step 4: Run test — expect green.**

Run: `make test-window-ocr`

Expected: `WindowOCRTests passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/KeyMic/Context/WindowOCRProvider.swift \
        Tests/WindowOCRTests.swift
git commit -m "feat(window-ocr): add resolvedRecognitionLanguages helper (LOR-20)"
```

---

## Task 3: Pure-logic `pickFocusedWindow(in:frontPID:)` over injected protocol

**Files:**
- Modify: `Sources/KeyMic/Context/WindowOCRProvider.swift` (add `WindowCandidate` protocol + `pickFocusedWindow` helper)
- Modify: `Tests/WindowOCRTests.swift` (heuristic tests on fakes)

`SCWindow` is not constructible from tests (no public initializer). Extract the heuristic onto a value-type protocol the production code refines with an `SCWindow` extension; tests use a trivial struct.

- [ ] **Step 1: Write failing tests.**

In `Tests/WindowOCRTests.swift` `main()`, add:

```swift
        testPickFocusedWindow_picksLargestOnScreenLayerZero()
        testPickFocusedWindow_filtersOffScreen()
        testPickFocusedWindow_filtersNonZeroLayer()
        testPickFocusedWindow_filtersForeignPID()
        testPickFocusedWindow_emptyReturnsNil()
        testPickFocusedWindow_noMatchingPIDReturnsNil()
```

Add at the bottom of the struct:

```swift
    struct FakeWindow: WindowCandidate, Equatable {
        let owningPID: pid_t?
        let isOnScreen: Bool
        let windowLayer: Int
        let frameArea: CGFloat
        var debugID: String  // for distinguishing in assertion failures
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
```

- [ ] **Step 2: Run test — expect compile failure (`WindowCandidate` / `pickFocusedWindow` missing).**

Run: `make test-window-ocr 2>&1 | head -10`

Expected: `error: cannot find type 'WindowCandidate' in scope`.

- [ ] **Step 3: Add `WindowCandidate` + `pickFocusedWindow` to `WindowOCRProvider.swift`.**

Append (above the `actor WindowOCRProvider` declaration, since the protocol is used both internally and by tests):

```swift
/// Test-friendly view of the SCWindow fields used by the focused-window heuristic.
/// Production code conforms `SCWindow` to this protocol via an extension below.
protocol WindowCandidate {
    var owningPID: pid_t? { get }
    var isOnScreen: Bool { get }
    var windowLayer: Int { get }
    var frameArea: CGFloat { get }
}
```

Then append inside the actor (after `resolvedRecognitionLanguages`):

```swift
    /// Picks the focused window from a list of candidates, using the heuristic:
    /// - Owning PID matches the frontmost application.
    /// - `isOnScreen == true`.
    /// - `windowLayer == 0` (filters inspectors / floating panels at higher layers).
    /// - Among survivors, the largest `frameArea`.
    /// Returns nil if no candidate qualifies (e.g. Finder desktop, all windows minimized).
    nonisolated static func pickFocusedWindow<W: WindowCandidate>(
        in candidates: [W],
        frontPID: pid_t
    ) -> W? {
        let filtered = candidates.filter {
            $0.owningPID == frontPID && $0.isOnScreen && $0.windowLayer == 0
        }
        return filtered.max { $0.frameArea < $1.frameArea }
    }
```

At the bottom of the file (outside the actor), add the SCWindow conformance — guarded so the test runner (which only compiles the helper module without ScreenCaptureKit) still builds. Since the test target DOES need to link, see Step 4 for the Makefile linkage. For now:

```swift
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

@available(macOS 14.0, *)
extension SCWindow: WindowCandidate {
    var owningPID: pid_t? { owningApplication?.processID }
    var frameArea: CGFloat { frame.width * frame.height }
}
#endif
```

- [ ] **Step 4: Update Makefile to link ScreenCaptureKit (needed because the `#if canImport(ScreenCaptureKit)` block in the source forces ScreenCaptureKit into the test binary).**

Replace the `test-window-ocr:` rule in `Makefile`:

```makefile
test-window-ocr:
	mkdir -p .build
	swiftc Sources/KeyMic/Context/WindowOCRProvider.swift \
	       Tests/WindowOCRTests.swift \
	       -framework ScreenCaptureKit \
	       -framework AppKit \
	       -o .build/window-ocr-tests
	.build/window-ocr-tests
```

- [ ] **Step 5: Run test — expect green.**

Run: `make test-window-ocr`

Expected: `WindowOCRTests passed`.

- [ ] **Step 6: Commit.**

```bash
git add Sources/KeyMic/Context/WindowOCRProvider.swift \
        Tests/WindowOCRTests.swift \
        Makefile
git commit -m "feat(window-ocr): add WindowCandidate + pickFocusedWindow heuristic (LOR-20)"
```

---

## Task 4: Capture path — `recognize()` + SCShareableContent + SCScreenshotManager

**Files:**
- Modify: `Sources/KeyMic/Context/WindowOCRProvider.swift` (add `recognize()` + private capture helper)

**No unit test — ScreenCaptureKit can't run in a `swiftc` runner against headless TCC.** Manual smoke only (see Task 10's matrix).

- [ ] **Step 1: Add `recognize()` skeleton and the SC capture helper.**

Append inside the actor (after `pickFocusedWindow`):

```swift
    /// Captures the focused window's pixels and returns recognized text.
    /// Returns nil when there's no focused window (no error — "no context" is a normal outcome).
    /// Throws on TCC denial or Vision errors so the caller can decide policy.
    func recognize() async throws -> String? {
        #if canImport(ScreenCaptureKit)
        guard #available(macOS 14.0, *) else { return nil }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Mirrors ScreenCapturer.captureAllScreens — TCC denial surfaces as a generic error here.
            throw WindowOCRError.screenRecordingDenied
        }

        guard let frontApp = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else {
            return nil
        }
        guard let scWindow = Self.pickFocusedWindow(in: content.windows, frontPID: frontApp.processIdentifier) else {
            return nil
        }

        let cgImage: CGImage
        do {
            cgImage = try await captureImage(of: scWindow)
        } catch {
            throw WindowOCRError.captureFailed(error)
        }

        // Vision step lands in Task 5.
        _ = cgImage
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(ScreenCaptureKit)
    @available(macOS 14.0, *)
    private func captureImage(of scWindow: SCWindow) async throws -> CGImage {
        // Resolve the backing scale by matching scWindow's display to NSScreen.
        let scale = await MainActor.run { () -> CGFloat in
            NSScreen.screens.first { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let id else { return false }
                return scWindow.frame.intersects(screen.frame.applying(.identity)) && id != 0
            }?.backingScaleFactor ?? 2.0
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.scalesToFit = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    #endif
```

- [ ] **Step 2: Build — expect green (no test changes, no test step).**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

Run also: `make test-window-ocr`

Expected: `WindowOCRTests passed` (the pure-logic tests still cover what we have; no new unit test for capture).

- [ ] **Step 3: Manual smoke (deferred to Task 10's matrix). For now confirm that:**

- `WindowOCRProvider.shared.recognize()` is callable from `await` context (no signature errors).
- The function returns nil (no OCR yet — Vision step lands in Task 5).

This is a no-unit-test step; capture+Vision integration is covered by the smoke matrix in §8 of the spec / Task 10 below.

- [ ] **Step 4: Commit.**

```bash
git add Sources/KeyMic/Context/WindowOCRProvider.swift
git commit -m "feat(window-ocr): add SCScreenshotManager capture path (LOR-20)"
```

---

## Task 5: Vision OCR — `VNRecognizeTextRequest`

**Files:**
- Modify: `Sources/KeyMic/Context/WindowOCRProvider.swift` (wire Vision into `recognize()`)

**No unit test — Vision results depend on macOS version and pixel buffers.** Manual smoke only (Task 10).

- [ ] **Step 1: Replace the `_ = cgImage; return nil` placeholder in `recognize()` with the Vision call.**

Edit `Sources/KeyMic/Context/WindowOCRProvider.swift`. Find:

```swift
        // Vision step lands in Task 5.
        _ = cgImage
        return nil
```

Replace with:

```swift
        do {
            return try Self.recognizeText(in: cgImage)
        } catch {
            throw WindowOCRError.visionFailed(error)
        }
```

Then add a new `import Vision` at the top of the file (alongside the existing `import AppKit` / `import CoreGraphics`):

```swift
import Vision
```

And add the static helper at the bottom of the actor:

```swift
    /// Runs Vision on a captured window image and returns top-to-bottom concatenated text.
    /// Returns nil if Vision found no candidate strings (e.g. screenshot of a blank canvas).
    @available(macOS 14.0, *)
    nonisolated static func recognizeText(
        in cgImage: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) throws -> String? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: recognitionLevel,
            revision: VNRecognizeTextRequest.currentRevision
        )) ?? []
        request.recognitionLanguages = resolvedRecognitionLanguages(
            preferred: Locale.preferredLanguages,
            supported: supported
        )
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
```

- [ ] **Step 2: Build.**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 3: Update Makefile target to link Vision so the test binary still compiles** (the source file now has `import Vision`):

Edit the `test-window-ocr:` rule in `Makefile`:

```makefile
test-window-ocr:
	mkdir -p .build
	swiftc Sources/KeyMic/Context/WindowOCRProvider.swift \
	       Tests/WindowOCRTests.swift \
	       -framework ScreenCaptureKit \
	       -framework AppKit \
	       -framework Vision \
	       -o .build/window-ocr-tests
	.build/window-ocr-tests
```

- [ ] **Step 4: Run test runner — expect green (pure-logic tests still pass).**

Run: `make test-window-ocr`

Expected: `WindowOCRTests passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/KeyMic/Context/WindowOCRProvider.swift Makefile
git commit -m "feat(window-ocr): wire VNRecognizeTextRequest into recognize() (LOR-20)"
```

---

## Task 6: `PersonaContextBuilder.build(for:clipboardStore:onStatusUpdate:)`

**Files:**
- Create: `Sources/KeyMic/LLM/PersonaContextBuilder.swift`
- Modify: `Tests/WindowOCRTests.swift` (add stub-provider tests for conditional gather)
- Modify: `Makefile` (extend `test-window-ocr` rule to compile dependencies)

Conditional, per-source gather. Pure-logic test uses a stubbable adapter — extract the side effects (selection read, clipboard read, OCR call) behind a struct of closures so tests can substitute them.

- [ ] **Step 1: Write failing tests.**

In `Tests/WindowOCRTests.swift` `main()`, add:

```swift
        testBuilder_gathersOnlyDeclaredSources()
        testBuilder_emptyContextSourcesGathersNothing()
        testBuilder_postsStatusUpdateForOCR()
        testBuilder_swallowsOCRThrow()
        testBuilder_canonicalOrderViaPersonaContext()
```

Add at the bottom of the runner struct:

```swift
    static func testBuilder_gathersOnlyDeclaredSources() {
        var selectionCalls = 0
        var clipboardTopCalls = 0
        var clipboardHistoryCalls = 0
        var ocrCalls = 0
        let providers = PersonaContextBuilder.Providers(
            selection: { selectionCalls += 1; return "SEL" },
            clipboardTop: { clipboardTopCalls += 1; return "CLIP" },
            clipboardHistory: { _ in clipboardHistoryCalls += 1; return ["h1", "h2"] },
            windowOCR: { ocrCalls += 1; return "OCR" }
        )
        let sources: Set<ContextSource> = [.selection, .windowOCR]
        let ctx = await PersonaContextBuilder.testBuild(sources: sources, providers: providers, onStatusUpdate: { _ in })
        expect(selectionCalls == 1, "selection should be called once, got \(selectionCalls)")
        expect(clipboardTopCalls == 0, "clipboardTop must NOT be called when not declared, got \(clipboardTopCalls)")
        expect(clipboardHistoryCalls == 0, "clipboardHistory must NOT be called when not declared")
        expect(ocrCalls == 1, "windowOCR should be called once, got \(ocrCalls)")
        expect(ctx.selection == "SEL", "selection field wrong: \(String(describing: ctx.selection))")
        expect(ctx.clipboardTop == nil, "clipboardTop should be nil")
        expect(ctx.clipboardHistory == nil, "clipboardHistory should be nil")
        expect(ctx.windowOCR == "OCR", "windowOCR field wrong: \(String(describing: ctx.windowOCR))")
    }

    static func testBuilder_emptyContextSourcesGathersNothing() {
        var anyCalled = false
        let providers = PersonaContextBuilder.Providers(
            selection: { anyCalled = true; return "X" },
            clipboardTop: { anyCalled = true; return "X" },
            clipboardHistory: { _ in anyCalled = true; return ["X"] },
            windowOCR: { anyCalled = true; return "X" }
        )
        let ctx = await PersonaContextBuilder.testBuild(sources: [], providers: providers, onStatusUpdate: { _ in })
        expect(!anyCalled, "no provider should be called for empty sources")
        expect(ctx == PersonaContext.empty, "context should equal .empty for empty sources")
    }

    static func testBuilder_postsStatusUpdateForOCR() {
        var statuses: [String] = []
        let providers = PersonaContextBuilder.Providers(
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

    static func testBuilder_swallowsOCRThrow() {
        let providers = PersonaContextBuilder.Providers(
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

    static func testBuilder_canonicalOrderViaPersonaContext() {
        // Builder doesn't re-implement ordering — it produces a PersonaContext whose
        // buildPrompt emits the canonical order. Smoke check that the integration holds.
        let providers = PersonaContextBuilder.Providers(
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
```

Mark `main()` `async` (Swift permits `@main` `async` main since 5.5):

```swift
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
```

The builder tests need to be `async` themselves (they call `await PersonaContextBuilder.testBuild(...)`). Mark them with `static func ... async`:

```swift
    static func testBuilder_gathersOnlyDeclaredSources() async { ... }
    static func testBuilder_emptyContextSourcesGathersNothing() async { ... }
    static func testBuilder_postsStatusUpdateForOCR() async { ... }
    static func testBuilder_swallowsOCRThrow() async { ... }
    static func testBuilder_canonicalOrderViaPersonaContext() async { ... }
```

- [ ] **Step 2: Run test — expect compile failure (no `PersonaContextBuilder`).**

Run: `make test-window-ocr 2>&1 | head -10`

Expected: `error: cannot find 'PersonaContextBuilder' in scope`.

- [ ] **Step 3: Implement `PersonaContextBuilder.swift`.**

`Sources/KeyMic/LLM/PersonaContextBuilder.swift`:

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Assembles a `PersonaContext` from the sources a persona declares.
/// Centralises what used to be inline in `AppDelegate.finishTranscription`.
///
/// Cheap sources (selection, clipboard) are gathered synchronously; the slow
/// `.windowOCR` source is awaited last and posts a "Reading screen…" status
/// via `onStatusUpdate`. Provider errors are swallowed — a missing source
/// degrades the prompt but never blocks the LLM call.
@MainActor
enum PersonaContextBuilder {
    /// Side-effect adapters. Production callsites use `.live(...)`; tests inject stubs.
    struct Providers {
        var selection: () -> String?
        var clipboardTop: () -> String?
        var clipboardHistory: (_ limit: Int) -> [String]?
        var windowOCR: () async throws -> String?
    }

    /// Convenience entry point — wires the real providers (`SelectionTextProvider`,
    /// `NSPasteboard.general`, `ClipboardStore.shared`, `WindowOCRProvider.shared`).
    static func build(
        for persona: Persona,
        clipboardStore: ClipboardStore = .shared,
        onStatusUpdate: @escaping (String) -> Void = { _ in }
    ) async -> PersonaContext {
        let providers = Providers.live(clipboardStore: clipboardStore)
        return await gather(sources: persona.contextSources,
                            providers: providers,
                            onStatusUpdate: onStatusUpdate)
    }

    /// Test entry point — bypasses Persona / ClipboardStore wiring.
    /// Same logic as `build(for:)` but exposes the providers directly.
    static func testBuild(
        sources: Set<ContextSource>,
        providers: Providers,
        onStatusUpdate: @escaping (String) -> Void
    ) async -> PersonaContext {
        await gather(sources: sources, providers: providers, onStatusUpdate: onStatusUpdate)
    }

    private static func gather(
        sources: Set<ContextSource>,
        providers: Providers,
        onStatusUpdate: (String) -> Void
    ) async -> PersonaContext {
        var selection: String? = nil
        var clipboardTop: String? = nil
        var clipboardHistory: [String]? = nil
        var windowOCR: String? = nil

        // 1. Cheap synchronous sources first.
        if sources.contains(.selection) {
            selection = providers.selection()
        }
        if sources.contains(.clipboardTop) {
            clipboardTop = providers.clipboardTop()
        }
        if sources.contains(.clipboardHistory) {
            clipboardHistory = providers.clipboardHistory(10)
        }

        // 2. Slow async OCR last, with status update.
        if sources.contains(.windowOCR) {
            onStatusUpdate(String(localized: "Reading screen…"))
            do {
                windowOCR = try await providers.windowOCR()
            } catch {
                // Permission denial / capture failure: skip silently. The caller
                // (AppDelegate) is responsible for any one-time TCC permission toast.
                windowOCR = nil
            }
        }

        return PersonaContext(
            selection: selection,
            clipboardTop: clipboardTop,
            clipboardHistory: clipboardHistory,
            windowOCR: windowOCR
        )
    }
}

extension PersonaContextBuilder.Providers {
    /// Real-world adapter wiring the existing app singletons.
    static func live(clipboardStore: ClipboardStore) -> Self {
        #if canImport(AppKit)
        return Self(
            selection: { SelectionTextProvider.currentSelection() },
            clipboardTop: { NSPasteboard.general.string(forType: .string) },
            clipboardHistory: { limit in clipboardStore.recentTexts(limit: limit) },
            windowOCR: { try await WindowOCRProvider.shared.recognize() }
        )
        #else
        return Self(
            selection: { nil },
            clipboardTop: { nil },
            clipboardHistory: { _ in nil },
            windowOCR: { nil }
        )
        #endif
    }
}
```

- [ ] **Step 4: Update Makefile `test-window-ocr` rule to compile builder + its dependencies (PersonaContext, ContextSource).**

The builder references `Persona`, `PersonaContext`, `ContextSource`, `ClipboardStore`, etc. The test runner only needs the builder's *pure-logic* path — and that's reachable via `testBuild(sources:providers:onStatusUpdate:)` without touching `Persona` or `ClipboardStore`. To keep the test target lean:

Add a lightweight test-only stub of `ClipboardStore.shared` is **not** possible (the real one is SwiftData-backed); instead, factor the test path so `testBuild` does not need `ClipboardStore` at all. The signature above already achieves this — `testBuild` calls `gather(sources:providers:onStatusUpdate:)` directly with the injected `Providers`.

But the file `PersonaContextBuilder.swift` references `ClipboardStore` inside `Providers.live(...)`. Since tests don't call `.live(...)`, we can still compile by giving the test runner stub types for `ClipboardStore`, `SelectionTextProvider`, etc. — that's heavy.

Simpler: split the live wiring into a separate file so tests compile only the pure builder.

Move `Providers.live(...)` into a new file `Sources/KeyMic/LLM/PersonaContextBuilder+Live.swift`:

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension PersonaContextBuilder.Providers {
    static func live(clipboardStore: ClipboardStore) -> Self {
        #if canImport(AppKit)
        return Self(
            selection: { SelectionTextProvider.currentSelection() },
            clipboardTop: { NSPasteboard.general.string(forType: .string) },
            clipboardHistory: { limit in clipboardStore.recentTexts(limit: limit) },
            windowOCR: { try await WindowOCRProvider.shared.recognize() }
        )
        #else
        return Self(
            selection: { nil },
            clipboardTop: { nil },
            clipboardHistory: { _ in nil },
            windowOCR: { nil }
        )
        #endif
    }
}
```

Remove the `extension PersonaContextBuilder.Providers { static func live(...) ... }` block from `PersonaContextBuilder.swift`. Also remove `build(for:)` from `PersonaContextBuilder.swift` and move it into `PersonaContextBuilder+Live.swift`:

```swift
extension PersonaContextBuilder {
    /// Convenience entry point — wires the real providers via `.live(clipboardStore:)`.
    static func build(
        for persona: Persona,
        clipboardStore: ClipboardStore = .shared,
        onStatusUpdate: @escaping (String) -> Void = { _ in }
    ) async -> PersonaContext {
        let providers = Providers.live(clipboardStore: clipboardStore)
        return await testBuild(sources: persona.contextSources,
                               providers: providers,
                               onStatusUpdate: onStatusUpdate)
    }
}
```

This leaves `PersonaContextBuilder.swift` self-contained (no `Persona` or `ClipboardStore` reference) so the test runner compiles just that file plus `PersonaContext.swift` + `ContextSource.swift` + `WindowOCRProvider.swift` + the test file.

Update the Makefile `test-window-ocr` rule:

```makefile
test-window-ocr:
	mkdir -p .build
	swiftc Sources/KeyMic/Context/WindowOCRProvider.swift \
	       Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/LLM/PersonaContextBuilder.swift \
	       Tests/WindowOCRTests.swift \
	       -framework ScreenCaptureKit \
	       -framework AppKit \
	       -framework Vision \
	       -o .build/window-ocr-tests
	.build/window-ocr-tests
```

Note: `PersonaContext.swift` has `#if canImport(AppKit)` guards around `snapshotCurrent()` that reference `SelectionTextProvider`. The test runner doesn't link `SelectionTextProvider.swift`, so if Swift complains about an unresolved symbol, wrap the `snapshotCurrent()` body in a `#if canImport(AppKit) && SUPPORTS_SELECTION_PROVIDER` shim — but in practice the unresolved symbol won't link because no test calls `snapshotCurrent()`. If linking does fail, add `Sources/KeyMic/LLM/SelectionTextProvider.swift` to the test target's source list.

Actually, since `SelectionTextProvider.currentSelection()` IS called inside `PersonaContext.swift`'s `snapshotCurrent()`, the symbol must resolve at link time. Add it:

```makefile
test-window-ocr:
	mkdir -p .build
	swiftc Sources/KeyMic/Context/WindowOCRProvider.swift \
	       Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/LLM/PersonaContextBuilder.swift \
	       Sources/KeyMic/LLM/SelectionTextProvider.swift \
	       Sources/KeyMic/LLM/PasteboardSnapshot.swift \
	       Sources/KeyMic/LLM/SelectionCopyWait.swift \
	       Tests/WindowOCRTests.swift \
	       -framework ScreenCaptureKit \
	       -framework AppKit \
	       -framework Vision \
	       -framework Carbon \
	       -o .build/window-ocr-tests
	.build/window-ocr-tests
```

(`SelectionTextProvider.swift` transitively pulls `PasteboardSnapshot` and `SelectionCopyWait` per LOR-17 plan; `Carbon` framework is needed for the input-source TIS calls referenced by `TextInjector`-adjacent code. If the linker reports missing symbols, expand this list incrementally.)

- [ ] **Step 5: Run test — expect green.**

Run: `make test-window-ocr`

Expected: `WindowOCRTests passed`.

If linker fails on unresolved symbols, add the missing source files to the rule until it links. Likely additions: none more — the builder is structured to not pull `ClipboardStore`.

- [ ] **Step 6: Run `make build` to confirm the new file compiles into the main app.**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit.**

```bash
git add Sources/KeyMic/LLM/PersonaContextBuilder.swift \
        Sources/KeyMic/LLM/PersonaContextBuilder+Live.swift \
        Tests/WindowOCRTests.swift \
        Makefile
git commit -m "feat(persona): add PersonaContextBuilder with conditional source gather (LOR-20)"
```

---

## Task 7: Migrate `AppDelegate.finishTranscription` to use `PersonaContextBuilder.build`

**Files:**
- Modify: `Sources/KeyMic/AppDelegate.swift` (line ~392-393)

- [ ] **Step 1: Find the current callsite.**

In `Sources/KeyMic/AppDelegate.swift`, lines 392-393 currently read:

```swift
        let context = PersonaContext.snapshotCurrent()
        let userText = context.buildPrompt(transcript: trimmed, sources: persona.contextSources)
        overlayPanel.showRefining()
        refiner.refine(userText, systemPrompt: persona.stylePrompt, temperature: persona.temperature) { [weak self] result in
```

- [ ] **Step 2: Replace with async builder call.**

The surrounding function `finishTranscription(text:)` is synchronous. Wrap the new context-building + refine call in a `Task { @MainActor in ... }` so the existing closure-style refiner callback still composes. Replace the block from `let context = ...` through `refiner.refine(...)` with:

```swift
        overlayPanel.showRefining()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = await PersonaContextBuilder.build(
                for: persona,
                onStatusUpdate: { [weak self] status in
                    self?.overlayPanel.updateText(status)
                }
            )
            let userText = context.buildPrompt(transcript: trimmed, sources: persona.contextSources)
            refiner.refine(userText, systemPrompt: persona.stylePrompt, temperature: persona.temperature) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let refined):
                    let finalText = refined.isEmpty ? trimmed : refined
                    self.overlayPanel.dismiss()
                    self.routeAndInject(text: finalText,
                                        strategy: persona.injectionStrategy,
                                        context: context)
                case .failure(let error):
                    self.logger.error("Refine failed: \(error.localizedDescription, privacy: .public)")
                    self.overlayPanel.showMessage(String(localized: "Refine failed: \(error.localizedDescription)"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.overlayPanel.dismiss()
                        self?.routeAndInject(text: trimmed,
                                             strategy: persona.injectionStrategy,
                                             context: context)
                    }
                }
            }
        }
```

Concrete diff — remove the OLD block (lines 392-414):

```swift
        let context = PersonaContext.snapshotCurrent()
        let userText = context.buildPrompt(transcript: trimmed, sources: persona.contextSources)
        overlayPanel.showRefining()
        refiner.refine(userText, systemPrompt: persona.stylePrompt, temperature: persona.temperature) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let refined):
                let finalText = refined.isEmpty ? trimmed : refined
                self.overlayPanel.dismiss()
                self.routeAndInject(text: finalText,
                                    strategy: persona.injectionStrategy,
                                    context: context)
            case .failure(let error):
                logger.error("Refine failed: \(error.localizedDescription, privacy: .public)")
                self.overlayPanel.showMessage(String(localized: "Refine failed: \(error.localizedDescription)"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.overlayPanel.dismiss()
                    self?.routeAndInject(text: trimmed,
                                         strategy: persona.injectionStrategy,
                                         context: context)
                }
            }
        }
```

And replace with the new `overlayPanel.showRefining()` + `Task { @MainActor [weak self] in ... }` block from above.

- [ ] **Step 3: Build.**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 4: Run all touched test suites.**

Run: `make test-window-ocr test-persona-context 2>&1 | grep -E "passed|FAIL"`

Expected: both `WindowOCRTests passed` and the existing PersonaContext runner passed line.

- [ ] **Step 5: Commit.**

```bash
git add Sources/KeyMic/AppDelegate.swift
git commit -m "refactor(persona): AppDelegate uses PersonaContextBuilder.build (LOR-20)"
```

---

## Task 8: Overlay "Reading screen…" status confirmation

**Files:**
- No code changes required (Task 7 already wired `onStatusUpdate` → `overlayPanel.updateText`).

This task is a **verification-only** task — confirm the spec §6 behavior is correct under the existing overlay state machine.

- [ ] **Step 1: Read OverlayPanel to confirm `updateText(_:)` semantics during the "refining" state.**

Open `Sources/KeyMic/OverlayPanel.swift`. Note that `showRefining()` sets `state.showsText = false`. A subsequent `updateText(_:)` call sets `state.showsText = true` AND `state.text = ...`. So the order of operations in `finishTranscription` matters:

- `overlayPanel.showRefining()` is called BEFORE the `Task { ... }` — this hides text and shows the animating wave.
- Inside the Task, `onStatusUpdate("Reading screen…")` calls `overlayPanel.updateText(...)` which re-shows text + label.
- After the OCR returns, the next overlay event is `refiner.refine` completion (success path dismisses, failure path shows a message).

Acceptable per spec §6 ("Cleared when context build completes. Replaced by 'Refining…' (or whatever LLMRefiner posts) once the LLM call starts."). The current LLMRefiner does NOT post a "Refining…" toast — the wave alone is the refining indicator. To match spec, push the wave-only state back after OCR completes by calling `showRefining()` AGAIN right after context gather.

- [ ] **Step 2: Add the post-OCR overlay reset.**

In `AppDelegate.swift`, inside the `Task { @MainActor [weak self] in ... }` block from Task 7, after `let context = await PersonaContextBuilder.build(...)`, BEFORE `let userText = ...`, add:

```swift
            // Return to the wave-only "refining" indicator after context gather.
            self.overlayPanel.showRefining()
```

The block now reads:

```swift
        overlayPanel.showRefining()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = await PersonaContextBuilder.build(
                for: persona,
                onStatusUpdate: { [weak self] status in
                    self?.overlayPanel.updateText(status)
                }
            )
            // Return to the wave-only "refining" indicator after context gather.
            self.overlayPanel.showRefining()
            let userText = context.buildPrompt(transcript: trimmed, sources: persona.contextSources)
            refiner.refine(userText, systemPrompt: persona.stylePrompt, temperature: persona.temperature) { [weak self] result in
                ...
```

- [ ] **Step 3: Build.**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 4: Commit.**

```bash
git add Sources/KeyMic/AppDelegate.swift
git commit -m "feat(window-ocr): overlay reverts to wave indicator after Reading screen status (LOR-20)"
```

---

## Task 9: One-time toast on missing Screen Recording permission

**Files:**
- Modify: `Sources/KeyMic/AppDelegate.swift` (new helper `maybeShowOCRPermissionToast`)

Per spec §5.5: persona declaring `.windowOCR` while Screen Recording is denied should see a one-time toast pointing to System Settings. Rate-limited via `UserDefaults` boolean.

- [ ] **Step 1: Add the helper to `AppDelegate.swift`** (place near other private helpers, e.g. after `routeAndInject`):

```swift
    /// Shows a one-time toast when a persona declares `.windowOCR` but Screen Recording TCC is denied.
    /// Rate-limited per launch via UserDefaults.
    private func maybeShowOCRPermissionToast() {
        let key = "windowOCRPermissionToastShown"
        if UserDefaults.standard.bool(forKey: key) { return }
        if WindowOCRProvider.hasScreenRecordingPermission() { return }
        UserDefaults.standard.set(true, forKey: key)
        overlayPanel.showTransientToast(
            String(localized: "Screen Recording permission needed for Window OCR"),
            durationSeconds: 4.0
        )
        // Best-effort: open the Privacy pane on click — not interactive in current toast,
        // so we log the URL for advanced users.
        logger.info("Open: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
```

- [ ] **Step 2: Call the helper before kicking off context gather** when the persona declares `.windowOCR`.

Modify the new `Task { @MainActor [weak self] in ... }` block from Task 7/8. Just before the `let context = await PersonaContextBuilder.build(...)` call, insert:

```swift
            if persona.contextSources.contains(.windowOCR) {
                self.maybeShowOCRPermissionToast()
            }
```

Note ordering: the toast is shown BEFORE the builder runs. The builder itself will still try the OCR and silently swallow the throw (per Task 6 implementation) — but the user has already been told why the prompt will lack `[Window text]`.

- [ ] **Step 3: Build.**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 4: Manual smoke** (deferred to Task 10, but you can verify by running the app and revoking Screen Recording via:

```bash
tccutil reset ScreenCapture io.keymic.app
```

Then trigger voice with a persona declaring `.windowOCR`; the toast should appear ONCE, subsequent triggers in the same launch are silent.

- [ ] **Step 5: Commit.**

```bash
git add Sources/KeyMic/AppDelegate.swift
git commit -m "feat(window-ocr): one-time permission toast for missing Screen Recording (LOR-20)"
```

---

## Task 10: Final verification — `make test-all` green + manual smoke matrix

**Files:** None (verification only).

- [ ] **Step 1: Run full test suite.**

Run: `script -q /dev/null make test-all 2>&1 | tail -3`

Expected: `✅ All tests passed`. Every runner should print `… passed`, including `WindowOCRTests passed`.

- [ ] **Step 2: Clean rebuild.**

Run: `make clean && make build 2>&1 | tail -5`

Expected: `Build complete!` with no `error:` lines. Codesigned `KeyMic.app` created.

- [ ] **Step 3: Manual smoke matrix (per spec §8).**

Launch the app:

```bash
make run
```

Then walk through this matrix. Mark each row P (pass) or F (fail) in the PR description.

| Setup | Persona setup | Expected | Result |
|---|---|---|---|
| Safari article in focus | new persona, prompt: "Summarize the article on screen", contextSources: `[.windowOCR]` | Refined output references article body content | |
| Empty TextEdit document | same persona | `[Window text]` empty / minimal; persona still produces output | |
| Two-monitor setup, focus on secondary | same persona | Captures secondary monitor's window | |
| Screen Recording permission revoked via `tccutil reset ScreenCapture io.keymic.app` | same persona | One-time toast "Screen Recording permission needed for Window OCR"; persona runs WITHOUT `[Window text]`; no crash | |
| No focused window (Finder desktop) | same persona | `windowOCR` nil, prompt has no `[Window text]` section, persona still runs | |
| Chinese-language article (Simplified Chinese article in Safari) | same persona, system locale `zh-Hans` | OCR captures Chinese text correctly | |
| Rapid-fire voice triggers (3 within 2s) | same persona | Serialized OCR via actor; no overlapping captures; final prompt uses latest capture | |

- [ ] **Step 4: Acceptance criteria checklist (spec §12).**

Self-verify each item in `docs/persona-platform/2026-05-23-lor-20-window-ocr.md` §12:

- [ ] `WindowOCRProvider.recognize()` returns non-empty text for the front Safari article on a typical workstation.
- [ ] Provider returns nil (not throws) when there's no focused window.
- [ ] Provider throws `.screenRecordingDenied` when TCC is revoked; `PersonaContextBuilder` catches and skips the source.
- [ ] Persona declaring `[.windowOCR]` sees `[Window text]` section populated in the LLM prompt.
- [ ] Persona declaring `[.windowOCR]` alongside `[.selection]` and `[.clipboardTop]` sees all three sections in canonical order.
- [ ] Overlay shows "Reading screen…" while OCR runs.
- [ ] One-time toast on missing Screen Recording permission; toast does not repeat within the same launch.
- [ ] `make test-window-ocr` passes (pure-logic helpers).
- [ ] Manual smoke matrix fully green.
- [ ] p95 end-to-end OCR latency < 600 ms on representative content. Log the timing (the provider's `os.Logger` debug line emits OCR duration).
- [ ] No log line contains OCR text content or window titles.

If any item is red, file a follow-up task and document the gap in the PR description.

- [ ] **Step 5: Verify no references to legacy `PersonaContext.snapshotCurrent()` remain in `AppDelegate`.**

Run: `grep -n "snapshotCurrent" Sources/KeyMic/AppDelegate.swift`

Expected: empty (the callsite was replaced in Task 7). `snapshotCurrent()` may still be defined in `PersonaContext.swift` — leave it for now (used by tests + future callers).

- [ ] **Step 6: Verify there are no leftover `print()` / debug stmts.**

Run: `grep -n "print(" Sources/KeyMic/Context/WindowOCRProvider.swift Sources/KeyMic/LLM/PersonaContextBuilder.swift Sources/KeyMic/LLM/PersonaContextBuilder+Live.swift`

Expected: empty.

- [ ] **Step 7: Final commit (if any cleanup needed). Otherwise skip.**

```bash
git status
# If anything is dirty:
git add -A
git commit -m "chore(window-ocr): final cleanup post smoke matrix (LOR-20)"
```

---

## Notes for the implementer

- **No XCTest.** All tests are standalone `swiftc` runners under `Tests/`, registered in `Makefile` via `test-<name>` targets, and chained into `test-all`. Match `Tests/PasteboardSnapshotTests.swift` / `Tests/ContextSourceTests.swift` style: `@main struct ...TestRunner { static func main() { ... } }` printing `... passed` on success and `exit(1)` on failure.
- **Async main.** Task 6 makes `main()` async — that's supported since Swift 5.5 with `@main`. No additional config needed.
- **Logger.** Subsystem `io.keymic.app`, category `WindowOCR` (add a `Logger(subsystem: "io.keymic.app", category: "WindowOCR")` inside the provider). Per spec §7: `.debug` on entry + result, `.error` on cases. **Never log OCR text or window titles.**
- **Actor concurrency.** `WindowOCRProvider` is an actor so concurrent voice triggers serialize. The two static helpers (`resolvedRecognitionLanguages`, `pickFocusedWindow`) are `nonisolated static` so they're callable without `await`. `hasScreenRecordingPermission()` is also `nonisolated static` for the same reason.
- **Commit cadence.** One green commit per task. Conventional commits: `feat(window-ocr): ...` for the provider, `feat(persona): ...` for the builder, `refactor(persona): ...` for the AppDelegate migration, `chore(window-ocr): ...` for cleanup. Every commit ends in `(LOR-20)`.
- **`make test-all` is the canonical green-light.** Pipe through `script -q /dev/null` if the rtk tee wrapper truncates output.
- **Permissions.** The build is codesigned with a local self-signed identity — re-grant Screen Recording to `KeyMic.app` after rebuilds if the cdhash changes:

```bash
tccutil reset ScreenCapture io.keymic.app
# then re-grant via System Settings → Privacy & Security → Screen Recording
```

- **Backing scale resolution.** Spec §5.2 uses `NSScreen.screens.first { ... }.backingScaleFactor`. The capture helper in Task 4 does a `.frame.intersects(...)` match; if smoke testing shows wrong scaling on multi-monitor setups (e.g. text comes back at half-resolution), replace the matcher with `SCWindow.displayID`-style matching once available — for macOS 14 the safest fallback is `NSScreen.main!.backingScaleFactor`.
- **Performance.** Spec §9 budgets < 600 ms p95. Add a `os_signpost`-style timing log in the provider once smoke is green if needed; out of scope for this plan.

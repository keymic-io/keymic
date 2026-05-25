# Window OCR Context Provider (LOR-20 / R2.3)

> **Status:** Draft · 2026-05-23
> **Linear:** https://linear.app/lorne/issue/LOR-20
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P3
> **Dependencies:** [LOR-18 Context Sources](2026-05-22-lor-18-context-sources.md) — `ContextSource.windowOCR` + `PersonaContext.windowOCR` already shipped
> **Consumers:** any persona that declares `[.windowOCR]` in its `contextSources` set

---

## 1. Context

Phase 2 (LOR-18) already added the *declarative* half of window OCR:

- `ContextSource.windowOCR` enum case exists.
- `PersonaContext.windowOCR: String?` field exists.
- `PersonaContext.buildPrompt(transcript:sources:)` emits the `[Window text]` section when both the source is requested and the field is populated.

What's missing: the **provider** — something that, when a persona declares `.windowOCR`, actually captures the focused window's pixels, runs OCR, and populates `PersonaContext.windowOCR` before the LLM call.

This spec defines that provider and wires it into the existing voice pipeline.

## 2. Goals

- One async function: `WindowOCRProvider.recognize() async throws -> String?` — captures the focused window and returns plain OCR text.
- Reuse existing `ScreenCapturer` (`SCShareableContent` / `SCScreenshotManager`) infrastructure.
- Hide all ScreenCaptureKit + Vision complexity behind that single call.
- Make context assembly **conditional on the active persona** — don't pay the OCR cost (100–500 ms + screen recording permission churn) for personas that don't declare `.windowOCR`.
- Overlay feedback: a "Reading screen…" status while OCR runs so the user knows the panel isn't frozen.
- Graceful degradation: missing Screen Recording permission, no focused window, OCR failure → nil return + log, never crash.

## 3. Non-Goals

- Word-level bounding boxes / layout reconstruction. Plain top-to-bottom concatenated text only.
- Multi-window OCR (e.g. "all visible Safari windows"). Focused window only.
- Image-based reasoning beyond Vision text recognition (no GPT-4V style image→LLM). The persona platform stays text-in / text-out.
- Background pre-OCR / caching across recordings. Each invocation captures fresh.
- Live region detection (e.g. "skip the menu bar"). Whole window captured, OCR de-noising left to the LLM.
- Configurable OCR languages per persona. Recognition language list is global and read from `Locale.preferredLanguages` at provider construction time.

## 4. Public API

### 4.1 Provider

**File:** `Sources/KeyMic/Context/WindowOCRProvider.swift` (new — sits alongside the future `SelectedTextReader` Context module).

```swift
import AppKit
import ScreenCaptureKit
import Vision

enum WindowOCRError: Error {
    case noFocusedWindow              // NSWorkspace returned nil / window not in SCShareableContent
    case screenRecordingDenied        // TCC denial — surfaces as SCShareableContent failure
    case captureFailed(Error)         // SCScreenshotManager threw
    case visionFailed(Error)          // VNImageRequestHandler / VNRecognizeTextRequest threw
}

actor WindowOCRProvider {
    static let shared = WindowOCRProvider()

    /// Captures the currently focused window and returns recognized text.
    /// Returns nil when there's no focused window (rather than throwing —
    /// callers treat "no window" as "no context" and proceed without it).
    /// Throws on capture / Vision errors so the caller can decide policy.
    func recognize(recognitionLevel: VNRequestTextRecognitionLevel = .accurate) async throws -> String?

    /// Returns true if Screen Recording TCC is granted (so callers can skip the call entirely
    /// and avoid a stray TCC prompt mid-recording).
    func hasScreenRecordingPermission() -> Bool
}
```

### 4.2 Context assembly entry point

**File:** `Sources/KeyMic/LLM/PersonaContextBuilder.swift` (new — extracts context-gathering away from `AppDelegate.buildUserText` / `finishTranscription`).

`AppDelegate` today reads selection + clipboard inline before invoking `PersonaContext.buildPrompt`. With LOR-20 adding an async OCR fetch, the inline pattern stops scaling. Introduce a dedicated assembler:

```swift
@MainActor
enum PersonaContextBuilder {
    /// Reads only the sources the persona actually declared in `persona.contextSources`.
    /// `.selection` and `.clipboardTop` / `.clipboardHistory` are synchronous —
    /// `.windowOCR` is async (recognize() takes 100–500 ms).
    /// Posts overlay status updates via the supplied `onStatusUpdate` closure when
    /// OCR or any other slow source is active.
    static func build(
        for persona: Persona,
        clipboardStore: ClipboardStore = .shared,
        onStatusUpdate: (String) -> Void = { _ in }
    ) async -> PersonaContext
}
```

Sequence inside `build`:

1. Init mutable fields: `selection: String? = nil`, `clipboardTop: String? = nil`, `clipboardHistory: [String]? = nil`, `windowOCR: String? = nil`.
2. If `persona.contextSources.contains(.selection)` → `selection = SelectionTextProvider.currentSelection()`.
3. If `persona.contextSources.contains(.clipboardTop)` → `clipboardTop = NSPasteboard.general.string(forType: .string)`.
4. If `persona.contextSources.contains(.clipboardHistory)` → `clipboardHistory = clipboardStore.recentTexts(limit: 10)`.
5. If `persona.contextSources.contains(.windowOCR)`:
   - `onStatusUpdate(String(localized: "Reading screen…"))`
   - `windowOCR = try? await WindowOCRProvider.shared.recognize()`
6. Return `PersonaContext(selection:, clipboardTop:, clipboardHistory:, windowOCR:)`.

The order matters: cheap sources first, expensive OCR last, so a slow OCR doesn't block already-known fields.

### 4.3 AppDelegate wiring

Replace the inline context-gathering block in `finishTranscription(text:)` (today: direct calls to `SelectionTextProvider`, `NSPasteboard.string(forType:)`):

```swift
let context = await PersonaContextBuilder.build(
    for: persona,
    onStatusUpdate: { [weak self] status in self?.overlayPanel.showStatus(status) }
)
let userText = context.buildPrompt(transcript: transcript, sources: persona.contextSources)
let refined = try await LLMRefiner.shared.refine(userText,
                                                  systemPrompt: persona.stylePrompt,
                                                  temperature: persona.temperature)
```

The voice state machine's grace-period handling is unchanged — context gathering simply happens between transcription finalization and LLM dispatch, both already async.

## 5. Behavior

### 5.1 Focused window selection

```swift
private func findFocusedWindow(in content: SCShareableContent) -> SCWindow? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontApp.processIdentifier
    // SCWindow.owningApplication is optional and may be nil for system windows.
    let frontWindows = content.windows.filter { $0.owningApplication?.processID == pid }
    // Prefer the on-screen, frontmost (largest z-order) layer-0 window.
    return frontWindows
        .filter { $0.isOnScreen && $0.windowLayer == 0 }
        .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
}
```

Notes:
- `SCWindow.frame` is in **points**, top-left origin (CG-style). No coordinate conversion required for the capture path — `SCContentFilter(desktopIndependentWindow:)` handles that internally.
- Picking the largest area among layer-0 on-screen windows is a heuristic that prefers content windows over inspectors/floating panels. Documented as a known limitation.
- KeyMic's own panels are filtered out by process id (they belong to KeyMic, not the front app).

### 5.2 Capture

```swift
let filter = SCContentFilter(desktopIndependentWindow: scWindow)
let config = SCStreamConfiguration()
config.showsCursor = false
config.width  = Int(scWindow.frame.width  * backingScale)
config.height = Int(scWindow.frame.height * backingScale)
config.scalesToFit = false
config.captureResolution = .best
let cgImage = try await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: config
)
```

`backingScale` resolved by matching `scWindow`'s display id against `NSScreen.screens` (same pattern as `ScreenCapturer.captureAllScreens`).

If `SCShareableContent.excludingDesktopWindows(...)` throws → translate to `.screenRecordingDenied` (mirrors existing `ScreenCapturer` convention).

### 5.3 OCR

```swift
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
let request = VNRecognizeTextRequest()
request.recognitionLevel = recognitionLevel       // .accurate by default
request.usesLanguageCorrection = true
request.recognitionLanguages = preferredLanguages  // from Locale.preferredLanguages, sanitized via VNRecognizeTextRequest.supportedRecognitionLanguages
try handler.perform([request])

let lines = (request.results ?? []).compactMap {
    $0.topCandidates(1).first?.string
}
return lines.isEmpty ? nil : lines.joined(separator: "\n")
```

- **Recognition level**: `.accurate` is the default; consumers can pass `.fast` if latency is critical. P3 ships with `.accurate` and re-evaluates if benchmarks show > 500 ms p95.
- **Language list**: derived from `Locale.preferredLanguages`, intersected with `VNRecognizeTextRequest.supportedRecognitionLanguages(for: revision)`. Vision will pick the best within that list per region; empty list → Vision default (English).
- **Output shape**: top-to-bottom concatenation with `\n`. No bounding-box reconstruction, no column detection.

### 5.4 Caps & truncation

Window OCR can produce kilobytes. `PersonaContext.buildPrompt` already enforces a 7500 UTF-16 cap on the *assembled* prompt and snaps at a character boundary (P1 behavior carried over). The provider does **not** truncate — it returns the full OCR text and lets the prompt assembler decide. This keeps the provider's contract simple ("return what Vision said") and centralizes truncation policy.

### 5.5 Permission handling

`hasScreenRecordingPermission()` uses the standard test:

```swift
func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
}
```

If false:
- `PersonaContextBuilder.build` skips the OCR step and emits a one-time overlay toast: `"Screen Recording permission needed for Window OCR"` + a link to Settings (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`).
- The persona proceeds without `[Window text]` — degraded but functional.
- Toast is rate-limited to once per launch (UserDefaults boolean).

This mirrors how `SelectionTextProvider` silently returns nil when AX permission is missing — the persona platform never blocks on a permission, it adapts.

### 5.6 Concurrency & cancellation

- `WindowOCRProvider` is an `actor` to serialize concurrent calls (e.g. if the user rapid-fires voice triggers, only one OCR runs at a time).
- A `Task` initiated by `PersonaContextBuilder.build` runs until completion; voice state machine has no cancellation hook for context-builder mid-flight, and `recognize()` typically completes in 100–500 ms so timeout isn't a hot issue. Add a 2-second `Task.withTimeout` wrapper around the OCR step inside the builder if benchmarks show p99 latency > 2 s.

## 6. Overlay UX

`OverlayPanel.showStatus(_ message: String)` already exists (used by ClipboardTransformer for "Transforming N items…"). Reuse:

- `"Reading screen…"` displayed for the duration of `recognize()`.
- Cleared when context build completes.
- Replaced by `"Refining…"` (or whatever LLMRefiner posts) once the LLM call starts.

No new UI primitive needed.

## 7. Logging

Subsystem `io.keymic.app`, category `WindowOCR`.

- `.debug` on `recognize()` entry: front-app bundle id, window title NOT logged (PII), window frame size.
- `.debug` on result: char count of returned text, OCR duration ms.
- `.error` on `WindowOCRError` cases: case name + underlying error description.
- **No PII**: never log OCR text content, never log window title.

## 8. Test Strategy

`make test-window-ocr` (new runner).

### Pure-logic tests (no AppKit / no Vision)

Extract the language-list filter as a static helper:

```swift
extension WindowOCRProvider {
    static func resolvedRecognitionLanguages(
        preferred: [String],
        supported: [String]
    ) -> [String]
}
```

Assert:

1. `resolvedRecognitionLanguages(preferred: ["zh-Hans-CN", "en-US"], supported: ["en-US", "zh-Hans", "fr-FR"]) → ["zh-Hans", "en-US"]` (BCP-47 prefix match, preferred order preserved).
2. `resolvedRecognitionLanguages(preferred: [], supported: ["en-US"]) → []` (let Vision default).
3. `resolvedRecognitionLanguages(preferred: ["xx-YY"], supported: ["en-US"]) → []` (no match — let Vision default rather than ship an unsupported language).

Extract a focused-window picker helper (pure on an injected `[SCWindow]`-like value type) and test the largest-area-on-screen heuristic.

### Integration with ScreenCaptureKit + Vision

Not unit-tested — Vision OCR results vary by macOS version and require a real screen buffer. Manual smoke matrix below covers it.

### Manual smoke matrix

| Setup | Persona | Expected |
|---|---|---|
| Safari article in focus | persona with `[.windowOCR]` + prompt "Summarize the article on screen" | Summary references article content |
| Empty TextEdit document | same persona | `[Window text]` empty / minimal, prompt still works |
| Two-monitor setup, focus on secondary display | same persona | Captures the window on the secondary, not the primary |
| Screen Recording permission revoked | same persona | One-time toast, persona runs WITHOUT `[Window text]`, no crash |
| No focused window (Finder desktop) | same persona | `windowOCR` nil, `[Window text]` section omitted, persona still runs |
| Chinese-language article | persona with `[.windowOCR]` on a zh-Hans system | OCR returns Chinese text correctly |
| Rapid-fire voice triggers (3 in 2 sec) | same persona | Serialized OCR (actor), no overlapping captures |

## 9. Performance budget

- Target: **< 600 ms** p95 from "voice transcription finalized" to "LLM call dispatched" with `[.windowOCR]` active.
  - Window resolution & capture: < 150 ms
  - VNRecognizeTextRequest `.accurate`: < 400 ms on typical 1440×900 window
  - Overhead: < 50 ms
- If p95 exceeds 600 ms in real use, switch default to `.fast` and document the trade-off in this spec.

## 10. Persona seed updates

This spec does NOT add new built-in personas. Window OCR is a building block; product-shaped personas using it ("Prompt Optimizer", "Summarize visible article") will be added in their own tickets.

For testing, users can create a custom persona via PersonasView with:
- `stylePrompt`: "You will receive the OCR'd text of the user's currently focused window under [Window text]. Use it as context to answer their spoken question."
- `contextSources`: `[.windowOCR]`
- `injectionStrategy`: `.replaceFocusedText`

## 11. Open Questions

- **Should we cache the last OCR result for a few seconds** so rapid-fire personas don't re-OCR the same screen? Proposal: no in P3 — adds invalidation complexity and "screen changed since last OCR" subtleties; defer until we see real workloads where this matters.
- **Should the provider redact obviously sensitive content** (passwords, credit-card patterns) before returning OCR text to the LLM? Proposal: no in P3 — that's the user's responsibility (don't enable `.windowOCR` on personas while sensitive data is on screen). The existing `SecretScanner` is clipboard-focused; reusing it for OCR text is a follow-up if user feedback demands it.
- **`SCContentFilter(desktopIndependentWindow:)` vs `SCContentFilter(display:including:[window])`**: the former captures only the window's bounds even when occluded; the latter captures the window's region on the display, occluded areas show what's actually visible. P3 uses `desktopIndependentWindow` for predictability — but note that fully occluded windows still get captured at their last known content (per ScreenCaptureKit semantics).

## 12. Acceptance Criteria

- [ ] `WindowOCRProvider.recognize()` returns non-empty text for the front Safari article on a typical workstation.
- [ ] Provider returns nil (not throws) when there's no focused window (Finder desktop, all windows minimized).
- [ ] Provider throws `.screenRecordingDenied` when TCC is revoked; `PersonaContextBuilder` catches and skips the source.
- [ ] Persona declaring `[.windowOCR]` sees `[Window text]` section populated in the LLM prompt.
- [ ] Persona declaring `[.windowOCR]` alongside `[.selection]` and `[.clipboardTop]` sees all three sections in the canonical order (Selection → Clipboard → Window → Transcript).
- [ ] Overlay shows "Reading screen…" while OCR runs.
- [ ] One-time toast on missing Screen Recording permission; toast does not repeat within the same launch.
- [ ] `make test-window-ocr` passes (pure-logic helpers).
- [ ] Manual smoke matrix in §8 fully green.
- [ ] p95 end-to-end OCR latency < 600 ms on representative content (one informal benchmark run, results noted in PR description).
- [ ] No log line contains OCR text content or window titles.

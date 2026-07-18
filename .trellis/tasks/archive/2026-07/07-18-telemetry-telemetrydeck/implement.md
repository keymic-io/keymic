# Implementation Plan — Telemetry via TelemetryDeck

Execution order is dependency-first: dependency → wrapper → gating test → call sites →
UI/consent → verify. Each step lists its verification.

## 0. Pre-flight

- [ ] Create/obtain a TelemetryDeck app ID (dashboard). Record it for `Info.plist`.
      → verify: app ID string in hand (or note that dev will use Test Mode only).

## 1. Add the dependency

- [ ] `Package.swift`: add `.package(url:"https://github.com/TelemetryDeck/SwiftSDK", from:"2.14.0")`
      and add product `TelemetryDeck` to the `KeyMic` target.
      → verify: `swift build` (or `make build`) resolves TelemetryDeck at a 2.14.x tag,
        no 3.0 beta; build succeeds.
- [ ] Confirm no vendored native libraries are pulled in (inspect resolved graph).
      → verify: `swift package show-dependencies` lists only TelemetryDeck (+ Sparkle).

## 2. `TelemetryService` wrapper + sink protocol

- [ ] New `Sources/KeyMic/Telemetry/TelemetryService.swift`:
      - `protocol TelemetrySink` with one method per signal (for test injection).
      - `TelemetryDeckSink: TelemetrySink` — real impl calling `TelemetryDeck.signal(...)`.
      - `TelemetryService.shared` with `isEnabled`, `startIfEnabled()`, `setEnabled(_:)`,
        typed emit methods that no-op when `!isEnabled`.
      - Reads `telemetryEnabled` (default true) and `Info.plist` `TelemetryDeckAppID`.
      - `#if DEBUG` sets Test Mode.
      → verify: compiles; `TelemetryService` is the only file importing `TelemetryDeck`
        (`rg "import TelemetryDeck" Sources` → 1 hit).

## 3. Gating unit test (before wiring call sites)

- [ ] `Tests/…` standalone `swiftc` runner `test-telemetry-gating`:
      - inject a spy `TelemetrySink`; assert disabled→0 calls, enabled→correct signal
        name + payload keys, toggle-off mid-run→no further calls.
      - assert `SpeechEngineChoice` → `engine` string mapping is 1:1 for all 4 cases.
- [ ] Add `test-telemetry-gating:` rule to `Makefile` (list every source dep) and to
      the `test-all` list.
      → verify: `make test-telemetry-gating` prints "… passed", exit 0.

## 4. Wire launch + permission + tap signals

- [ ] `AppDelegate.applicationDidFinishLaunching`: call `TelemetryService.shared
      .startIfEnabled()` early (before KeyMonitor start so `event_tap_failed` can emit).
- [ ] After existing permission checks, emit `permissionState(...)` (AX, mic, speech,
      screenCapture → {granted,denied,undetermined}).
- [ ] `KeyMonitor` `CGEvent.tapCreate == nil` path (~L140) and/or `AppDelegate` L211
      `!AXIsProcessTrusted()`: emit `eventTapFailed()` before the alert/quit.
- [ ] Verify TelemetryDeck's automatic launch/session signal fires; if not, add one
      manual launch emit.
      → verify: Debug run + Test Mode → `permission_state` (and auto launch) appear in
        dashboard; simulate tap failure (revoke Accessibility) → `event_tap_failed`.

## 5. Wire speech-engine signals

- [ ] `applySpeechEnginePreference()` after `choose(...)`: emit `engineSelected(...)`,
      guarded by the generation counter so only the winning decision emits (no double
      emit on async swap).
- [ ] ONNX `AssetStore.fetchWithFallback` + SenseVoice `SenseVoiceModelStore` download:
      emit `modelDownload(...)` with `durationMs`, winning `source`, `result`,
      `errorKind?`.
- [ ] `SpeechEngine.swift` first-buffer (~L209) + watchdog (~L234): emit
      `engineColdStart(...)` once per session (`firstBufferMs`, `scoWatchdogFired`).
- [ ] Engine error callbacks: emit `transcribeError(engine, errorKind)` — coarse enum
      only, never message text.
      → verify: Debug run, use voice with a fresh model → `engine_selected`,
        `model_download`, `engine_cold_start` visible; force an engine error →
        `transcribe_error`. Confirm NO payload carries transcript text.

## 5b. Wire adoption signals

- [ ] `feature_used` at each feature entrypoint (voice trigger-down, `ClipboardController
      .toggle` L94, `PersonaEngine.run`, `KeyMappingManager` remap, `HotkeyActionRunner`,
      `ScreenshotController` capture, `VaultStore` add) — pass the fixed enum string.
- [ ] `persona_invoked` in `PersonaEngine.run` (persona name/id + injectionStrategy;
      never custom prompt text).
- [ ] `hotkey_action` in `HotkeyActionRunner` (HotkeyAction case name).
- [ ] `activation_first_transcription` on first successful final transcription, guarded
      by UserDefaults `activationFirstTranscriptionSent` (fires once ever).
      → verify: exercise each feature/persona/hotkey → matching signals in dashboard;
        first transcription emits activation once, second launch does not re-emit.
        Grep emit args to confirm no `persona` custom-prompt text or transcript leaks.

## 6. Settings toggle + first-run notice

- [ ] `GeneralSettingsView` (~L250): add `Toggle("Share anonymous diagnostics & crash
      reports")` bound to the shared `@AppStorage("telemetryEnabled")` (default true) +
      sub-label; onChange → `TelemetryService.shared.setEnabled(_:)`. (The Sentry sibling
      reads the same key; copy already covers crash reports.)
- [ ] First-run: `telemetryNoticeShown` flag; show one-time notice when enabled+unshown,
      then set flag.
- [ ] Append new UI strings to `.xcstrings` (append-only; do not reorder).
      → verify: toggle persists across launches; off → no SDK init & no network to
        TelemetryDeck (Charles/Console); notice appears exactly once.

## 7. Info.plist + build/sign

- [ ] Add `TelemetryDeckAppID` to `Info.plist`; keep `plutil -lint` clean.
- [ ] `make build` (release) + confirm codesign succeeds and app launches.
      → verify: `plutil -lint Info.plist` OK; app runs; if Accessibility TCC
        invalidated by rebuild, `tccutil reset` per CLAUDE.md.

## 8. Full-scope check

- [ ] `make test-all` green (includes `test-telemetry-gating`).
- [ ] Re-read PRD acceptance criteria; tick each with evidence.
- [ ] Confirm every changed line traces to this task (no unrelated refactors).

## Review gates

- After step 2: wrapper API review (is the boundary clean, one import site?).
- After step 5: privacy review — grep emit call args to prove no content leaks.
- Before commit: run `/code-review` against the branch; verify acceptance criteria.

## Rollback points

- Anytime: set `telemetryEnabled` default to false (one line) to ship dark.
- Full revert: drop the SPM package + `Telemetry/` dir; call sites reference a stubbed
  `TelemetryService` (compile-safe no-ops) or are removed together.

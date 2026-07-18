# Design — Anonymous diagnostics telemetry via TelemetryDeck

## Overview

One thin `TelemetryService` singleton wraps the TelemetryDeck SDK. It is the only
type that imports `TelemetryDeck`. Every diagnostic call site talks to
`TelemetryService`, never to the SDK directly, so:

- the opt-out toggle is enforced in exactly one place;
- swapping providers later touches one file;
- call sites stay declarative (`Telemetry.shared.engineSelected(...)`).

No backend, no queue, no HMAC — transport/batching is the SDK's job.

## Components

> **Codex PR-review fixes (post-implementation, commit `dd13a3a`):** opt-out now calls
> `TelemetryDeck.terminate()` + resets the sink; the gate (`isEnabled`/`sink`/`started`)
> is lock-serialized (emits fire from background download callbacks); `engine_selected`
> sends its locale under key `speechLocale` (TelemetryDeck reserves `locale`); the
> first-run notice runs before the no-AX / tap-fail early returns; `permission_state`
> is re-emitted from the `requestPermissions` completion handler; `engine_selected` is
> emitted only after the engine swap lands (per-engine + Apple on ONNX/SenseVoice
> fallback), generation-guarded.

> **Implemented split (deviation from the sketch below):** because the repo's
> standalone `swiftc` test runners cannot see SPM packages, `TelemetryService.swift`
> imports **no** SDK. The real SDK lives in a second file `TelemetryDeckSink.swift`
> (the sole `import TelemetryDeck` site). `TelemetryService` exposes a
> `sinkProvider: () -> TelemetrySink?` seam (default `{ nil }`); AppDelegate wires it
> to `{ TelemetryDeckSink.makeIfConfigured() }` before `startIfEnabled()`. SDK init
> (`TelemetryDeck.initialize(config: TelemetryDeck.Config(appID:))`, `config.testMode`
> under DEBUG) happens inside the sink factory, which no-ops when `Info.plist`
> `TelemetryDeckAppID` is absent. Confirmed: the SDK auto-sends a launch/session signal
> (`Config.sendNewSessionBeganSignal` default true) — so no manual `app_launch`.

### 1. `TelemetryService` (new — `Sources/KeyMic/Telemetry/TelemetryService.swift`)

```
final class TelemetryService {
    static let shared = TelemetryService()

    private(set) var isEnabled: Bool          // mirrors UserDefaults "telemetryEnabled" (default true)
    private var started = false

    func startIfEnabled()                      // called once from AppDelegate.applicationDidFinishLaunching
    func setEnabled(_ on: Bool)                // called by the Settings toggle
    // typed emit methods, one per signal (below) — each no-ops when !isEnabled
}
```

- **Init/gate:** `startIfEnabled()` reads `telemetryEnabled` (default `true`, same
  `object(forKey:) as? Bool ?? true` pattern used for `voiceEnabled`). If enabled,
  builds `TelemetryDeck.Config(appID:)` from `Info.plist` and calls
  `TelemetryDeck.initialize(config:)`. If disabled, does nothing — SDK never inits.
- **App ID source:** `Info.plist` key `TelemetryDeckAppID` (non-secret, same handling
  class as `SUFeedURL`). If the key is missing/empty, `startIfEnabled()` no-ops (fail
  safe; e.g. local dev without an app ID configured).
- **Runtime toggle:** `setEnabled(false)` sets `isEnabled = false` so all emit methods
  short-circuit immediately (SDK has no "stop" API mid-session; gating at the wrapper
  is sufficient and guarantees no new signals). `setEnabled(true)` flips the flag and
  calls `startIfEnabled()` if not yet started.
- **Debug builds:** set `config.testMode` appropriately (TelemetryDeck flags Debug
  signals as test by default) so emissions are self-testable via dashboard Test Mode.
  Guarded by `#if DEBUG`.
- **Safety:** every emit method is a thin, non-throwing call; SDK send failures are
  swallowed by the SDK. No emit blocks the main thread (SDK enqueues async).

Typed emit surface (payload values are `String`; keys fixed):

```
// diagnostics
func engineSelected(model:String, engine:String, osMajor:String, locale:String)
func modelDownload(model:String, result:String, durationMs:Int, source:String, errorKind:String?)
func engineColdStart(engine:String, firstBufferMs:Int, scoWatchdogFired:Bool)
func transcribeError(engine:String, errorKind:String)
func permissionState(mic:String, speech:String, accessibility:String, screenCapture:String)
func eventTapFailed()
// adoption
func featureUsed(_ feature:String)                       // enum: voice|clipboard|persona|keymap|hotkey|screenshot|vault
func personaInvoked(persona:String, injectionStrategy:String)
func hotkeyAction(_ action:String)
func activationFirstTranscription()                      // one-shot, guarded by UserDefaults flag
```

Signal names sent to TelemetryDeck: `engine_selected`, `model_download`,
`engine_cold_start`, `transcribe_error`, `permission_state`, `event_tap_failed`,
`feature_used`, `persona_invoked`, `hotkey_action`, `activation_first_transcription`.

### Consent flag is shared with the Sentry sibling

The opt-out preference is a **single shared UserDefaults key** `telemetryEnabled`
(default true). This task owns it, the Settings toggle, and the first-run notice. The
Sentry child reads the same key and is gated by it. `TelemetryService.isEnabled`
reflects this key; the Sentry child's service reads it independently (no cross-import).
Toggle copy: "Share anonymous diagnostics & crash reports" — already covers Sentry so
it needs no change when the sibling ships.

### 2. Instrumentation call sites (existing files, surgical additions)

| Signal | File / anchor |
|---|---|
| `engine_selected` | `AppDelegate.applySpeechEnginePreference()` (~L509) right after `SpeechEngineFactory.choose(...)` returns `choice`. `osMajor` from `ProcessInfo`, `locale` from the selected locale code, `model` from the picker pref, `engine` = choice case name. Gate on the generation counter so a superseded async decision does not double-emit — emit only for the decision that wins. |
| `model_download` | ONNX: `AssetStore.fetchWithFallback` (wrap success/failure + which source won → `source`). SenseVoice: `SenseVoiceModelStore` download completion. Measure `durationMs` around the fetch. `source` ∈ {huggingface, modelscope, github}; `errorKind` = coarse error label on failure. |
| `engine_cold_start` | **All 4 engines** (each passes its own `SpeechEngineChoice.telemetryName`): Apple `SpeechEngine.swift` (~L218/L249), `SpeechAnalyzerSpeechEngine.swift`, `ONNXSpeechEngine.swift`, `SenseVoiceSpeechEngine.swift` — each got a `sessionStartTime: DispatchTime?` captured in `startSession()` + emit once per session at first-buffer (`scoWatchdogFired:false`) and in the 0.8s watchdog (`scoWatchdogFired:true`). `firstBufferMs` = uptime delta session-start→first-buffer. (Implemented across all engines because the SCO watchdog value driver is SenseVoice/ONNX, not Apple.) |
| `transcribe_error` | Each engine's error callback routed through `SpeechSessionHost` / engine error path. `errorKind` = coarse enum, never the message text. |
| `permission_state` | `AppDelegate.applicationDidFinishLaunching`, after existing permission checks. Read AX (`AXIsProcessTrusted`), mic/speech (AVFoundation/Speech auth status), screen capture status → four enum strings {granted,denied,undetermined}. |
| `event_tap_failed` | `KeyMonitor.swift` (~L140) where `CGEvent.tapCreate` returns nil, and/or `AppDelegate` L211 `!AXIsProcessTrusted()` alert path — emit before the app shows its alert / quits. Best-effort: `startIfEnabled()` must have run first (it does, earlier in launch). |

Adoption call sites (existing files, one-line emits):

| Signal | File / anchor |
|---|---|
| `feature_used` | Each feature entrypoint: voice (`VoiceTrigger` trigger-down), clipboard (`ClipboardController.toggle` L94), persona (`PersonaEngine.run`), keymap (`KeyMappingManager` remap apply), hotkey (`HotkeyActionRunner`), screenshot (`ScreenshotController` capture start), vault (`VaultStore` add). Pass the fixed `feature` enum string. |
| `persona_invoked` | `PersonaEngine.run` (L21) — `persona` = built-in name / stable id (never custom prompt text), `injectionStrategy` = the resolved `InjectionStrategy` case name. |
| `hotkey_action` | `HotkeyActionRunner` (L6) dispatch — `action` = `HotkeyAction` case name. |
| `activation_first_transcription` | Final-transcription success path (`SpeechSessionHost` route-final). Guard with UserDefaults `activationFirstTranscriptionSent` so it fires once ever. |

`app_launch` is **not** emitted manually — TelemetryDeck's automatic launch/session
signal already carries appVersion/OS/arch. **Implementation must verify** this auto
signal actually fires; if not, add a single `Telemetry.shared` launch call.

### 3. Settings toggle (existing `SettingsRoot.swift` → `GeneralSettingsView`, ~L250)

Add a `Toggle("Share anonymous diagnostics", isOn:)` bound to a small view model /
`@AppStorage("telemetryEnabled")` (default true). On change → `TelemetryService.shared
.setEnabled(newValue)`. Sub-label: "Anonymous — never includes transcripts, clipboard,
keystrokes, or screen content. [Learn more]". Localized via the existing `.xcstrings`
flow (append-only, per project convention).

### 4. First-run notice

- UserDefaults flag `telemetryNoticeShown` (default false).
- On first launch where telemetry is enabled and the flag is false: present a one-time,
  non-blocking notice (menu-bar-style alert / notification consistent with how KeyMic
  already surfaces first-run/setup messaging), then set the flag.
- Copy: "KeyMic shares anonymous diagnostics to fix crashes and device-specific
  failures. It never includes your transcripts, clipboard, keystrokes, or screen
  content. Turn it off anytime in Settings › General."
- Mechanism is an implementation detail — reuse whatever first-run/onboarding surface
  exists; a plain one-shot notification is acceptable.

## Data flow

```
launch ─▶ AppDelegate.applicationDidFinishLaunching
           ├─ TelemetryService.shared.startIfEnabled()   (init SDK or no-op)
           ├─ permission checks ─▶ Telemetry.permissionState(...)
           └─ first-run notice (once)
KeyMonitor.start ─▶ tapCreate == nil ─▶ Telemetry.eventTapFailed()
voice use ─▶ applySpeechEnginePreference ─▶ Telemetry.engineSelected(...)
          ─▶ model fetch ─▶ Telemetry.modelDownload(...)
          ─▶ session ─▶ Telemetry.engineColdStart(...) / transcribeError(...)
Settings toggle ─▶ TelemetryService.setEnabled(bool)
```

## Dependency

`Package.swift`: add `.package(url: "https://github.com/TelemetryDeck/SwiftSDK", from:
"2.14.0")` and product `TelemetryDeck` to the `KeyMic` target. Pin below 3.0 to avoid
the beta line. Verify the release build still lipo/codesigns (Makefile + release.sh);
no vendored native libs are pulled in.

## Testing

Follows the repo's standalone `swiftc` runner convention (not XCTest). A pure unit is
possible for the **gating logic** by injecting a fake emitter into `TelemetryService`
(protocol `TelemetrySink` with a real TelemetryDeck-backed impl and a spy):

- `test-telemetry-gating`: when disabled, no sink call; when enabled, sink receives the
  expected signal name + payload keys; toggling off mid-run stops further calls.
- `SpeechEngineFactory.choose` already testable — assert `engine_selected`'s `engine`
  string maps 1:1 to the `SpeechEngineChoice` case for each branch.

End-to-end (manual, per acceptance criteria): run Debug build with Test Mode, exercise
voice, confirm signals in the TelemetryDeck dashboard; flip the toggle off and confirm
no network calls (Charles/Console).

## Boundaries & non-goals

- `TelemetryService` is the sole `import TelemetryDeck` site.
- No content ever crosses the boundary — emit methods only accept enums/durations/bools,
  never free text from transcripts/clipboard/OCR.
- No backend/keymic-web changes. No account correlation.

## Rollout / rollback

- Rollout: ships in a normal release; on by default, discoverable + disableable in
  Settings; first-run notice sets expectations.
- Rollback: a bad SDK interaction is defused by shipping with the toggle default flipped,
  or reverting the single dependency + `TelemetryService` (call sites become no-ops if
  the wrapper is stubbed). Because all emissions funnel through one type, disabling is
  one-line.

# Design — Sentry crash/error

> **Implementation reconciliation (steps 1–6 done, verified by trellis-check; step 7 DSN pending):**
> - Split into two files mirroring the Telemetry boundary: `CrashReportingCore.swift`
>   (Sentry-free — `ErrorKind`, lock-protected gate, `CrashScrub`, seams) so standalone
>   `swiftc` tests compile it, and `CrashReportingService.swift` (the sole `import Sentry`).
> - `scrub` returns non-optional (`-> E`): always scrub-in-place and keep the crash/error
>   event, never drop it wholesale. `beforeSend` returns the scrubbed event.
> - `ErrorKind` rides as a Sentry **tag** (`error_kind` + `capture_site`), not `extra`/userInfo
>   — the scrub drops all `extra`, tags survive. The synthetic error message is an
>   allowlisted `"KeyMic error: <kind>"`.
> - Scrub drops **all** breadcrumbs + **all** `extra`, blanks non-allowlisted messages; keeps
>   structured device/OS/app auto-contexts (content-free, needed for OS/app version).
> - `sentry-cocoa` resolved at **9.22.0**, **statically linked** — no framework-copy/sign step
>   (unlike Sparkle); the design's "confirm universal framework sign" note doesn't apply.
> - IP: no dedicated client flag; `sendDefaultPii = false` suppresses the SDK's auto IP.
> - `.llm` capture anchor is `PersonaEngine.complete(...)` (the live path), not
>   `LLMClient.refine` (only a Settings test button). Cancellation is filtered before capture.

## Overview

Mirror child-1's boundary pattern: one thin `CrashReportingService` singleton is the
sole `import Sentry` site. It owns SDK init, the `beforeSend` scrub hook, the consent
gate, and the small `capture(error:context:)` surface used by call sites.

Crashes are automatic (SDK default). Errors are captured only at a curated set of
otherwise-silent `catch` sites — never a blanket handler.

## Components

### 1. `CrashReportingService` (new — `Sources/KeyMic/Telemetry/CrashReportingService.swift`)

```
final class CrashReportingService {
    static let shared = CrashReportingService()
    private(set) var isEnabled: Bool          // reads shared "telemetryEnabled" (default true)
    private var started = false

    func startIfEnabled()                      // AppDelegate launch; no-op if flag off or DSN missing
    func setEnabled(_ on: Bool)                // called by the shared Settings toggle (child-1)
    func capture(_ kind: ErrorKind, file: StaticString = #fileID)   // coarse, content-free
}
enum ErrorKind: String { case llm, modelDownload, configSync, engineStart, ... }
```

- **Init:** `startIfEnabled()` reads the **shared** `telemetryEnabled` key (same key
  child-1 owns; no cross-import — just the UserDefaults key). If true and `Info.plist`
  `SentryDSN` is present, `SentrySDK.start { options in ... }`:
  - `options.dsn` from Info.plist
  - `options.sendDefaultPii = false`
  - IP disabled; no PII
  - `options.environment = "debug"` under `#if DEBUG` else `"production"`
  - `options.beforeSend = { event in scrub(event) }` (see §3)
  - tracing/profiling **off** (deferred); crash handler **on** (default)
- **Gate:** `setEnabled(false)` → `SentrySDK.close()` and `isEnabled = false` so
  `capture` no-ops. `close()` is effectively terminal for the session; re-enable takes
  effect next launch (documented; acceptable — matches "opt-out" expectation).
- **capture:** wraps `SentrySDK.capture(error:)` / `capture(message:)` with a synthetic,
  content-free error carrying only `ErrorKind` + `#fileID`. No user data.

### 2. Shared consent (owned by child-1)

- The Settings toggle and first-run notice already exist (child-1) and the copy already
  says "diagnostics & crash reports". This task adds **no UI**.
- child-1's `TelemetryService.setEnabled` must also call
  `CrashReportingService.shared.setEnabled` so one toggle drives both. Wiring point:
  the toggle's onChange (or a tiny shared `ConsentCoordinator`) calls both services.
  Chosen approach: the Settings toggle onChange calls both `TelemetryService.shared
  .setEnabled` and `CrashReportingService.shared.setEnabled`. (One line added in
  child-1's toggle handler when this task ships.)

### 3. `beforeSend` scrub hook (the privacy core)

- Allowlist mentality: keep only known-safe fields (exception type, stack frames,
  `ErrorKind` tag, OS/app version, `#fileID`).
- Drop/blank: any breadcrumb not explicitly marked safe; message strings that are not
  from our fixed set; any `extra`/`context` we did not set ourselves.
- Never attach: transcripts, clipboard, keys, OCR, secrets, file *contents*, full paths
  containing the username where avoidable.
- Unit-tested in isolation (pure function `scrub(event) -> event?`).

### 4. Instrumentation call sites (curated `catch` sites)

Selective — only where a failure is otherwise silent and diagnostically valuable:

| ErrorKind | Anchor |
|---|---|
| `llm` | `PersonaPlatform/Engine/LLMClient.swift` request `catch` |
| `modelDownload` | ONNX `AssetStore.fetchWithFallback` failure; SenseVoice `SenseVoiceModelStore` download failure (already emit TelemetryDeck `model_download` failure; also `capture(.modelDownload)`) |
| `configSync` | `Sync/ConfigSyncAPI` / `SyncEngine` request `catch` |
| `engineStart` | speech engine `start` failures (SenseVoice/ONNX cold-start hard failures) |

Each call passes only the `ErrorKind`; no thrown-error message text that could embed
user content. Where the underlying `Error` is a known typed enum with no content, it may
be passed to `capture(error:)`; otherwise use the synthetic error.

## Data flow

```
launch ─▶ AppDelegate ─▶ CrashReportingService.shared.startIfEnabled()
                          (reads shared telemetryEnabled; init Sentry or no-op)
crash ─────────────────▶ Sentry automatic handler ─▶ beforeSend scrub ─▶ upload
silent catch site ─────▶ CrashReportingService.capture(.kind) ─▶ scrub ─▶ upload
Settings toggle (child-1) ─▶ CrashReportingService.setEnabled(bool)
```

## Dependency

`Package.swift`: add `.package(url:"https://github.com/getsentry/sentry-cocoa", from:
"9.0.0")`, product `Sentry` to the `KeyMic` target. Verify lipo/codesign of the release
build (Sentry ships a framework; confirm universal build + notarization-free local sign
still succeed). This is the second and final new SPM dependency.

## Testing

Standalone `swiftc` runner convention:

- `test-crash-reporting-gating`: inject a fake Sentry-facing sink; disabled→no capture,
  enabled→capture with the right `ErrorKind` and no content fields.
- `test-crash-reporting-scrub`: feed crafted events (with breadcrumbs/message that
  *look* like leaked content) to `scrub(_:)`; assert they are dropped/blanked.

Manual E2E (acceptance): Debug build, force a crash + a captured error, confirm they
appear in the Sentry `debug` environment with a symbolicated stack and **no content**;
flip toggle off → no Sentry network.

## Boundaries & non-goals

- `CrashReportingService` is the sole `import Sentry` site.
- No tracing, no log forwarding, no session replay, no userId.
- No Settings UI or first-run notice (child-1 owns them).

## Rollout / rollback

- Rollout: ships after child-1; on by default via the shared toggle; DSN in Info.plist.
- Rollback: ship dark by flipping the shared default to false (affects both tools), or
  revert the SPM package + `CrashReportingService` + the one line in child-1's toggle
  handler + the curated capture calls. Single-import boundary keeps this contained.

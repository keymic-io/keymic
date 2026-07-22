# Implementation Plan — Sentry crash/error

Ships **after** child-1 (`07-18-telemetry-telemetrydeck`), which provides the shared
`telemetryEnabled` flag, Settings toggle, and first-run notice. Order: dependency →
wrapper + scrub → gating/scrub tests → init wiring → curated captures → toggle wiring →
Info.plist/build → verify.

## 0. Pre-flight

- [ ] Create a Sentry project (macOS/Apple), get the DSN. Record for `Info.plist`.
      → verify: DSN in hand.
- [ ] Confirm child-1 has shipped / merged (shared `telemetryEnabled` + toggle exist).
      → verify: `rg "telemetryEnabled" Sources` shows child-1's flag + toggle.

## 1. Add the dependency

- [ ] `Package.swift`: add `.package(url:"https://github.com/getsentry/sentry-cocoa", from:"9.0.0")`
      and product `Sentry` to the `KeyMic` target.
      → verify: `make build` resolves sentry-cocoa 9.x; build succeeds; total external
        deps = Sparkle + TelemetryDeck + Sentry.

## 2. `CrashReportingService` + scrub hook

- [ ] New `Sources/KeyMic/Telemetry/CrashReportingService.swift`:
      - `ErrorKind` enum; `shared`; `isEnabled` (reads shared `telemetryEnabled`);
        `startIfEnabled()`; `setEnabled(_:)`; `capture(_:file:)`.
      - `startIfEnabled` calls `SentrySDK.start` with `sendDefaultPii=false`, IP off,
        `environment` = debug/production, tracing off, crash handler on,
        `beforeSend = scrub`.
      - `scrub(_ event:) -> Event?` as a pure, testable function (allowlist).
      → verify: compiles; `rg "import Sentry" Sources` → exactly 1 hit.

## 3. Gating + scrub unit tests (before wiring)

- [ ] `test-crash-reporting-gating`: fake sink; disabled→0 captures; enabled→capture with
      right `ErrorKind`, no content fields.
- [ ] `test-crash-reporting-scrub`: crafted events with content-looking breadcrumbs/
      messages are dropped/blanked; safe fields preserved.
- [ ] Add both `test-*` rules to `Makefile` and to the `test-all` list.
      → verify: `make test-crash-reporting-gating test-crash-reporting-scrub` print
        "… passed", exit 0.

## 4. Init wiring

- [ ] `AppDelegate.applicationDidFinishLaunching`: call
      `CrashReportingService.shared.startIfEnabled()` (after reading the shared flag).
      → verify: Debug run → Sentry initialized in `debug` environment (SDK debug log);
        toggle-off run → not initialized.

## 5. Curated async-error captures

- [ ] `LLMClient` request `catch` → `capture(.llm)`.
- [ ] ONNX `AssetStore.fetchWithFallback` + SenseVoice download failure → `capture(.modelDownload)`.
- [ ] `ConfigSyncAPI` / `SyncEngine` `catch` → `capture(.configSync)`.
- [ ] Speech engine `start` hard-failure → `capture(.engineStart)`.
      → verify: force each error path → issue appears in dashboard with the ErrorKind
        tag and NO content; grep capture call args to confirm no message text from user
        data.

## 6. Toggle wiring (one line in child-1)

- [ ] In child-1's Settings toggle onChange handler, also call
      `CrashReportingService.shared.setEnabled(newValue)` so one toggle drives both.
      → verify: toggling off → `SentrySDK.close()`; no further Sentry network
        (Charles/Console); toggling on + relaunch → Sentry active again.

## 7. Info.plist + build/sign

- [ ] Add `SentryDSN` to `Info.plist`; keep `plutil -lint` clean.
- [ ] `make build` (release) → codesign + launch OK; confirm Sentry framework signs
      deeply like Sparkle (per CLAUDE.md codesign notes).
      → verify: `plutil -lint Info.plist` OK; app runs; forced crash symbolicates in
        dashboard.

## 8. Full-scope check

- [ ] `make test-all` green (includes the two new runners).
- [ ] Re-read PRD acceptance criteria + parent cross-child criteria; tick with evidence.
- [ ] Privacy review: manual inspection of a real captured event in the dashboard —
      zero content.
- [ ] Confirm every changed line traces to this task.

## Review gates

- After step 2: boundary + `beforeSend` allowlist review (one import site; scrub correct?).
- After step 5: privacy review of every capture call's arguments.
- Before commit: `/code-review` against the branch; verify acceptance criteria.

## Rollback points

- Ship dark: flip shared `telemetryEnabled` default to false (affects both tools).
- Full revert: drop the SPM package + `CrashReportingService` + the one line in child-1's
  toggle handler + curated capture calls.
